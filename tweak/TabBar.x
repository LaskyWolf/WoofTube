#import <YouTubeHeader/YTCommandResponderEvent.h>
#import <YouTubeHeader/YTIFormattedString.h>
#import <YouTubeHeader/YTISearchEndpoint.h>
#import <YouTubeHeader/YTPivotBarItemView.h>
#import <YouTubeHeader/YTRightNavigationButtons.h>
#import <objc/message.h>
#import "WoofTube.h"
#import "WTSearchResultsController.h"

// Puts a real UITabBarController with a real UISearchTab on top of YouTube. Its
// pages are empty and let touches through, so YouTube's screens stay where they
// are. YouTube's own bar stays in place, invisible, so it still decides when the
// bar shows and hides. A tap on a tab is forwarded to the matching YouTube tab.

@interface YTPivotBarView : UIView
@end

@interface YTICommand (WoofTube)
@property (nonatomic, readwrite, strong) YTISearchEndpoint *searchEndpoint;
@end

@interface YTRightNavigationButtons (WoofTube)
@property (nonatomic, readonly) UIControl *searchButton;
@end

// iOS 18 and 26 API missing from the SDK this tweak builds against.
@protocol WTTab <NSObject>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) UIImage *image;
@property (nonatomic, readonly) NSString *identifier;
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier viewControllerProvider:(UIViewController *(^)(id))provider;
- (instancetype)initWithViewControllerProvider:(UIViewController *(^)(id))provider;
- (void)setAutomaticallyActivatesSearch:(BOOL)value;
@end

@interface UITabBarController (WTModernTabs)
@property (nonatomic, copy) NSArray *tabs;
@property (nonatomic, strong) id<WTTab> selectedTab;
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated;
@end

static const CGFloat WTAvatarSize = 28.0;
static const int WTAvatarMaxRetries = 10;
// iPhone tab bars have five slots and search takes one. Any extra tab would make
// UIKit add its own More page.
static const NSUInteger WTMaxPivotTabs = 4;
static const NSTimeInterval WTSearchDismissDelay = 0.4;
static BOOL WTNativeBarDrawn;

static NSString *WTPivotIdentifier(YTPivotBarItemView *item) {
    return [item.renderer valueForKey:@"pivotIdentifier"]
        ?: [[item valueForKey:@"iconOnlyItemRenderer"] valueForKey:@"pivotIdentifier"];
}

static NSString *WTSymbolName(NSString *identifier) {
    return @{
        @"FEwhat_to_watch": @"house",
        @"FEshorts": @"play.square.stack",
        @"FEuploads": @"plus",
        @"FEsubscriptions": @"rectangle.stack.badge.play",
        @"FElibrary": @"person.crop.circle",
        @"FEexplore": @"safari",
    }[identifier] ?: @"circle";
}

static void WTCollectViews(UIView *view, Class cls, NSMutableArray *found) {
    if ([view isKindOfClass:cls]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) WTCollectViews(subview, cls, found);
}

static NSArray<YTPivotBarItemView *> *WTPivotItems(UIView *bar) {
    NSMutableArray *items = [NSMutableArray array];
    WTCollectViews(bar, %c(YTPivotBarItemView), items);
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [a convertPoint:CGPointZero toView:bar].x;
        CGFloat bx = [b convertPoint:CGPointZero toView:bar].x;
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    return items;
}

static void WTClearChrome(UIView *view) {
    // Removed instead of hidden, because YouTube shows its blur again while scrolling.
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        [view removeFromSuperview];
        return;
    }
    view.backgroundColor = UIColor.clearColor;
    for (UIView *subview in view.subviews) WTClearChrome(subview);
}

// Holds the tab controller's view. Touches on its empty pages go to YouTube.
@interface WTPassThroughView : UIView
@property (nonatomic, weak) UITabBarController *controller;
@end

@implementation WTPassThroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIViewController *page = self.controller.selectedViewController;
    if ([page isKindOfClass:UINavigationController.class]) page = ((UINavigationController *)page).topViewController;
    for (UIView *view = page.viewIfLoaded; view; view = view.superview) {
        if (view == hit) return nil;
    }
    return hit;
}

@end

static UIResponder *WTYouTubeResponder(UIResponder *responder) {
    SEL parent = NSSelectorFromString(@"parentResponder");
    while (responder && ![responder respondsToSelector:parent]) responder = responder.nextResponder;
    return responder;
}

@interface WTTabController : UITabBarController <UITabBarControllerDelegate, UISearchControllerDelegate>
- (NSString *)currentPivotTitle;
- (void)syncWithPivotBar:(UIView *)bar;
- (void)syncVisibilityWithPivotBar:(UIView *)bar;
- (void)installOverPivotBar:(UIView *)bar;
@end

@implementation WTTabController {
    WTPassThroughView *_container;
    NSArray<YTPivotBarItemView *> *_pivotItems;
    NSArray<NSString *> *_identifiers;
    NSMutableDictionary<NSString *, id<WTTab>> *_tabs;
    id<WTTab> _searchTab;
    id<WTTab> _tabBeforeSearch;
    UIViewController *_searchPage;
    UISearchController *_searchController;
    __weak UIResponder *_searchResponder;
    NSMutableDictionary<NSString *, NSString *> *_titles;
    BOOL _showingResults;
    BOOL _syncing;
    BOOL _barHidden;
    UIImage *_avatarSource;
    int _avatarRetries;
    BOOL _avatarRetryPending;
}

- (instancetype)init {
    if ((self = [super init])) {
        _tabs = [NSMutableDictionary dictionary];
        _titles = [NSMutableDictionary dictionary];
        self.delegate = self;
        _searchTab = [(id<WTTab>)[NSClassFromString(@"UISearchTab") alloc] initWithViewControllerProvider:^UIViewController *(id tab) {
            return [self makeSearchPage];
        }];
        if ([_searchTab respondsToSelector:@selector(setAutomaticallyActivatesSearch:)]) {
            [_searchTab setAutomaticallyActivatesSearch:YES];
        }
    }
    return self;
}

- (UIViewController *)makeSearchPage {
    WTSearchResultsController *results = [[WTSearchResultsController alloc] initWithStyle:UITableViewStylePlain];
    __weak WTTabController *weakSelf = self;
    results.onSubmit = ^(NSString *query) {
        [weakSelf showResultsForQuery:query];
    };
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = results;
    search.searchBar.delegate = results;
    search.delegate = self;
    _searchController = search;

    UIViewController *page = [UIViewController new];
    page.view.backgroundColor = UIColor.systemBackgroundColor;
    _searchPage = page;
    page.navigationItem.searchController = search;
    page.navigationItem.hidesSearchBarWhenScrolling = NO;

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = appearance;
    navigation.view.backgroundColor = UIColor.clearColor;
    // The empty bar must not block YouTube's top bar when the page is see-through.
    navigation.navigationBar.userInteractionEnabled = NO;
    return navigation;
}

- (id<WTTab>)tabForItem:(YTPivotBarItemView *)item identifier:(NSString *)identifier {
    id<WTTab> tab = _tabs[identifier];
    if (tab) return tab;

    NSString *title = [[item.renderer valueForKey:@"title"] stringWithFormattingRemoved]
        ?: item.navigationButton.accessibilityLabel;
    if (title) _titles[identifier] = title;
    // The full word doesn't fit next to four other tabs.
    if ([identifier isEqualToString:@"FEsubscriptions"] && title.length > 10) title = @"Subs";
    tab = [(id<WTTab>)[NSClassFromString(@"UITab") alloc] initWithTitle:title
                                                                 image:[UIImage systemImageNamed:WTSymbolName(identifier)]
                                                            identifier:identifier
                                                viewControllerProvider:^UIViewController *(id unused) {
        UIViewController *page = [UIViewController new];
        page.view.backgroundColor = UIColor.clearColor;
        return page;
    }];
    _tabs[identifier] = tab;
    return tab;
}

// The tab controller goes right above the full-screen view that holds YouTube's
// bar, so anything YouTube draws above its bar, like the player, stays on top.
- (void)installOverPivotBar:(UIView *)bar {
    UIWindow *window = bar.window;
    if (!window) return;

    UIView *child = bar;
    UIView *host = bar.superview;
    while (host && host != window && CGRectGetHeight(host.bounds) < CGRectGetHeight(window.bounds)) {
        child = host;
        host = host.superview;
    }
    if (!host || host == window) {
        host = window.rootViewController.view;
        child = nil;
    }
    if (_container.superview == host) return;

    UIResponder *responder = host;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    UIViewController *owner = (UIViewController *)responder;
    if (!owner) return;

    if (!_container) {
        _container = [[WTPassThroughView alloc] initWithFrame:host.bounds];
        _container.controller = self;
        _container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.view.frame = _container.bounds;
        self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.view.backgroundColor = UIColor.clearColor;
    }

    [self willMoveToParentViewController:nil];
    [self.view removeFromSuperview];
    [self removeFromParentViewController];

    [owner addChildViewController:self];
    _container.frame = host.bounds;
    if ([child isDescendantOfView:host] && child.superview == host) [host insertSubview:_container aboveSubview:child];
    else [host addSubview:_container];
    [_container addSubview:self.view];
    [self didMoveToParentViewController:owner];
    WTNativeBarDrawn = YES;
}

- (void)syncWithPivotBar:(UIView *)bar {
    // YouTube keeps spare item views with no tab behind them.
    NSMutableArray<YTPivotBarItemView *> *pivotItems = [NSMutableArray array];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (YTPivotBarItemView *item in WTPivotItems(bar)) {
        NSString *identifier = WTPivotIdentifier(item);
        if (!identifier.length) continue;
        if ([identifier isEqualToString:@"FEuploads"]) continue;
        if (WTEnabled([WTHideTabKeyPrefix stringByAppendingString:identifier])) continue;
        [pivotItems addObject:item];
        [identifiers addObject:identifier];
    }
    // The last tab is You, which must stay because Settings opens from it.
    while (pivotItems.count > WTMaxPivotTabs) {
        [pivotItems removeObjectAtIndex:pivotItems.count - 2];
        [identifiers removeObjectAtIndex:identifiers.count - 2];
    }
    _pivotItems = pivotItems;

    if (identifiers.count && ![identifiers isEqualToArray:_identifiers]) {
        _identifiers = identifiers;
        NSMutableArray *tabs = [NSMutableArray array];
        [pivotItems enumerateObjectsUsingBlock:^(YTPivotBarItemView *item, NSUInteger index, BOOL *stop) {
            [tabs addObject:[self tabForItem:item identifier:identifiers[index]]];
        }];
        [tabs addObject:_searchTab];
        _syncing = YES;
        self.tabs = tabs;
        _syncing = NO;
        _avatarSource = nil;
    }

    if (self.selectedTab != _searchTab) {
        for (NSUInteger index = 0; index < pivotItems.count; index++) {
            if (![[pivotItems[index] valueForKey:@"selected"] boolValue]) continue;
            id<WTTab> tab = _tabs[identifiers[index]];
            if (tab != self.selectedTab) {
                _syncing = YES;
                self.selectedTab = tab;
                _syncing = NO;
            }
            break;
        }
    }
    [self syncAvatar];
}

- (void)syncVisibilityWithPivotBar:(UIView *)bar {
    if ((self.selectedTab == _searchTab && !_showingResults) || !bar.window) return;
    BOOL visible = CGRectIntersectsRect([bar convertRect:bar.bounds toView:bar.window], bar.window.bounds);
    for (UIView *view = bar; visible && view; view = view.superview) {
        if (view.hidden || view.alpha <= 0) visible = NO;
    }
    if (visible == !_barHidden) return;
    _barHidden = !visible;
    [self setTabBarHidden:_barHidden animated:YES];
}

// The picture downloads after the bar appears, so a missing one is retried.
- (void)syncAvatar {
    NSUInteger index = [_identifiers indexOfObject:@"FElibrary"];
    if (index == NSNotFound || index >= _pivotItems.count) return;

    YTPivotBarItemView *item = _pivotItems[index];
    UIImageView *imageView = [item valueForKey:@"_avatarImageView"];
    UIImage *avatar = ([imageView isKindOfClass:UIImageView.class] ? imageView.image : nil)
        ?: [item valueForKey:@"_avatarImage"];
    if (!avatar) {
        if (_avatarRetryPending || _avatarRetries >= WTAvatarMaxRetries) return;
        _avatarRetries++;
        _avatarRetryPending = YES;
        __weak WTTabController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            WTTabController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_avatarRetryPending = NO;
            [strongSelf syncAvatar];
        });
        return;
    }
    if (avatar == _avatarSource) return;
    _avatarSource = avatar;

    CGRect rect = CGRectMake(0, 0, WTAvatarSize, WTAvatarSize);
    _tabs[@"FElibrary"].image = [[[[UIGraphicsImageRenderer alloc] initWithSize:rect.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        [avatar drawInRect:rect];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)forwardTapToPivotItem:(NSString *)identifier {
    NSUInteger index = [_identifiers indexOfObject:identifier];
    if (index == NSNotFound || index >= _pivotItems.count) return;

    YTPivotBarItemView *item = _pivotItems[index];
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    UIResponder *responder = item;
    while (responder && ![responder respondsToSelector:tap]) responder = responder.nextResponder;
    if (responder)
        ((void (*)(id, SEL, id))objc_msgSend)(responder, tap, item.renderer);
    else
        [item.navigationButton sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// Runs the search with YouTube's own command. The page turns see-through and
// lets touches through, so the results appear while the search tab stays selected.
- (void)showResultsForQuery:(NSString *)query {
    UIResponder *responder = _searchResponder ?: WTYouTubeResponder(_pivotItems.firstObject);
    if (!responder) return;

    _showingResults = YES;
    _searchController.active = NO;
    _searchPage.view.backgroundColor = UIColor.clearColor;

    YTISearchEndpoint *endpoint = [%c(YTISearchEndpoint) message];
    endpoint.query = query;
    YTICommand *command = [%c(YTICommand) message];
    command.searchEndpoint = endpoint;
    [[%c(YTCommandResponderEvent) eventWithCommand:command entry:nil sendClick:NO firstResponder:responder] send];
}

- (NSString *)currentPivotTitle {
    id<WTTab> tab = self.selectedTab == _searchTab ? _tabBeforeSearch : self.selectedTab;
    return _titles[tab.identifier];
}

- (void)resetSearchPage {
    _showingResults = NO;
    _searchPage.view.backgroundColor = UIColor.systemBackgroundColor;
}

- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectTab:(id<WTTab>)tab {
    if (tab == _searchTab && self.selectedTab != _searchTab) _tabBeforeSearch = self.selectedTab;
    return YES;
}

// YouTube handles a command by passing it up from the page on screen, so the
// search starts from that page. It must be found before the results list covers it.
- (void)willPresentSearchController:(UISearchController *)searchController {
    [self resetSearchPage];
    UIWindow *window = self.view.window;
    CGPoint center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    _searchResponder = WTYouTubeResponder([window hitTest:center withEvent:nil]);
}

- (void)tabBarController:(UITabBarController *)controller didSelectTab:(id<WTTab>)tab previousTab:(id<WTTab>)previousTab {
    if (_syncing || tab == _searchTab) return;
    // Results were pushed on the tab under search. Tapping that tab takes them off.
    if (_showingResults) {
        if (tab != _tabBeforeSearch) [self forwardTapToPivotItem:_tabBeforeSearch.identifier];
        [self resetSearchPage];
    }
    [self forwardTapToPivotItem:tab.identifier];
}

// Cancelling goes back to the previous tab. It waits for UIKit's own animation
// to end, because changing tabs during it leaves the bar stuck in its search state.
- (void)didDismissSearchController:(UISearchController *)searchController {
    if (_showingResults) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WTSearchDismissDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_showingResults || self->_searchController.active || self.selectedTab != self->_searchTab || !self->_tabBeforeSearch) return;
        self->_syncing = YES;
        self.selectedTab = self->_tabBeforeSearch;
        self->_syncing = NO;
    });
}

@end

static WTTabController *WTSharedTabController(void) {
    static WTTabController *controller;
    if (!controller) controller = [WTTabController new];
    return controller;
}

NSString *WTCurrentTabTitle(void) {
    return WTEnabled(WTNativeTabBarKey) ? [WTSharedTabController() currentPivotTitle] : nil;
}

%group WTNativeTabBar

// YouTube's floating bar is a separate class (YTFloatingPivotBarView) that the
// hooks below don't reach. These switches make YouTube use YTPivotBarView.
%hook YTColdConfig
- (BOOL)mainAppCoreClientHidePivotBarOnScrollInTabs { return NO; }
- (long long)mainAppCoreClientIosFloatingBarStyle { return 0; }
- (BOOL)mainAppCoreClientIosEnablePositionedFloatyBars { return NO; }
- (BOOL)mainAppCoreClientIos27EnableLiquidGlass { return NO; }
%end

%hook YTColdConfigMainAppCoreClientImpl
- (BOOL)hidePivotBarOnScrollInTabs { return NO; }
- (long long)iosFloatingBarStyle { return 0; }
- (BOOL)iosEnablePositionedFloatyBars { return NO; }
- (BOOL)ios27EnableLiquidGlass { return NO; }
%end

// Tab bars in Apple's apps stay on screen while scrolling.
%hook YTScrollableNavigationController
- (BOOL)hidePivotBarOnScroll { return NO; }
%end

%hook YTPivotBarView

- (void)setFloatingBarStyle:(long long)style {
    %orig(0);
}

- (void)setBackgroundColor:(UIColor *)color {
    %orig(UIColor.clearColor);
}

- (void)layoutSubviews {
    %orig;

    self.clipsToBounds = NO;
    self.backgroundColor = UIColor.clearColor;
    ((UIView *)[self valueForKey:@"separatorView"]).hidden = YES;
    // The views that only hold the bar would otherwise show dark behind the glass.
    for (UIView *view = self.superview; view && CGRectGetHeight(view.bounds) < CGRectGetHeight(self.window.bounds); view = view.superview) {
        view.backgroundColor = UIColor.clearColor;
    }
    for (UIView *subview in self.subviews) WTClearChrome(subview);
    for (YTPivotBarItemView *item in WTPivotItems(self)) item.alpha = 0.0;

    WTTabController *controller = WTSharedTabController();
    [controller installOverPivotBar:self];
    [controller syncWithPivotBar:self];
    [controller syncVisibilityWithPivotBar:self];
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    [WTSharedTabController() syncVisibilityWithPivotBar:self];
}

- (void)setAlpha:(CGFloat)alpha {
    %orig;
    [WTSharedTabController() syncVisibilityWithPivotBar:self];
}

- (void)setFrame:(CGRect)frame {
    %orig;
    [WTSharedTabController() syncVisibilityWithPivotBar:self];
}

%end

%hook YTPivotBarItemView

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    for (UIView *view = self.superview; view; view = view.superview) {
        if ([view isKindOfClass:%c(YTPivotBarView)]) {
            [view setNeedsLayout];
            break;
        }
    }
}

%end

// Lets YouTube's content scroll underneath the bar so the glass has something to show.
%hook YTPivotBarViewController
- (BOOL)isFrostedPivotBarPermitted { return YES; }
%end

// Search moves to the search tab once the tab controller is in place.
%hook YTRightNavigationButtons

- (void)layoutSubviews {
    %orig;
    self.searchButton.hidden = WTNativeBarDrawn;
}

%end

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{WTNativeTabBarKey: @YES}];
    // UITab and UISearchTab need iOS 18. Older systems keep YouTube's bar.
    if (WTEnabled(WTNativeTabBarKey) && NSClassFromString(@"UISearchTab")) %init(WTNativeTabBar);
}
