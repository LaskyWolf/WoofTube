#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "WoofTube.h"

// Puts real iOS glass (UIGlassEffect) behind the video player's buttons, in the
// places YouTube already draws them, and turns its autoplay switch into a matching button.

@interface YTFrostedGlassView : UIView
@end

@interface YTMainAppControlsOverlayView : UIView
@end

@interface ABCSwitch : UIControl
@end

@interface YTReelTopBarView : UIView
@end

static const CGFloat WTPlayerButtonGlassSize = 44.0;
static const void *WTGlassKey = &WTGlassKey;
static const void *WTAutoplayButtonKey = &WTAutoplayButtonKey;

static UIVisualEffectView *WTMakeGlass(void) {
    Class glass = NSClassFromString(@"UIGlassEffect"); // iOS 26
    if (!glass) return nil;
    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:[glass new]];
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    return view;
}

static UIVisualEffectView *WTGlassBehindContent(UIView *owner) {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, WTGlassKey);
    if (!glass) {
        glass = WTMakeGlass();
        if (!glass) return nil;
        objc_setAssociatedObject(owner, WTGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != owner) {
        [owner addSubview:glass];
        // Some of YouTube's icons are bare layers, which views don't order against.
        [owner.layer insertSublayer:glass.layer atIndex:0];
    }
    return glass;
}

static void WTAddCircleGlass(UIView *owner, CGFloat size, CGFloat centerY) {
    UIVisualEffectView *glass = WTGlassBehindContent(owner);
    glass.frame = CGRectMake((CGRectGetWidth(owner.bounds) - size) / 2, centerY - size / 2, size, size);
    glass.layer.cornerRadius = size / 2;
}

void WTAddButtonGlass(UIView *button) {
    if (![button isKindOfClass:UIView.class]) return;
    WTAddCircleGlass(button, WTPlayerButtonGlassSize, CGRectGetMidY(button.bounds));
}

static UIButton *WTAutoplayButton(UIControl *control) {
    return objc_getAssociatedObject(control, WTAutoplayButtonKey);
}

static void WTUpdateAutoplayButton(UIControl *control) {
    UIButton *button = WTAutoplayButton(control);
    BOOL on = [[control valueForKey:@"on"] boolValue];
    UIButtonConfiguration *configuration = button.configuration;
    configuration.image = [UIImage systemImageNamed:on ? @"play.circle.fill" : @"play.slash"];
    button.configuration = configuration;
    button.accessibilityValue = on ? @"On" : @"Off";
}

// Autoplay becomes a glass button like the ones next to it. It sits inside
// YouTube's control, so it fades and hides with it.
static void WTInstallAutoplayButton(UIControl *control) {
    if (![control isKindOfClass:UIControl.class] || WTAutoplayButton(control)) return;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.baseForegroundColor = UIColor.whiteColor;
    __weak UIControl *weakControl = control;
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
        UIControl *strongControl = weakControl;
        [strongControl setValue:@(![[strongControl valueForKey:@"on"] boolValue]) forKey:@"on"];
        [strongControl sendActionsForControlEvents:UIControlEventValueChanged];
        WTUpdateAutoplayButton(strongControl);
    }]];
    button.accessibilityLabel = @"Autoplay";
    objc_setAssociatedObject(control, WTAutoplayButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addSubview:button];
    [control setNeedsLayout];
}

static BOOL WTIsInsidePlayer(UIView *view) {
    for (UIView *current = view.superview; current; current = current.superview) {
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"Overlay"] || [name containsString:@"Player"] || [name containsString:@"Watch"]) return YES;
    }
    return NO;
}

%group WTPlayerGlass

// YouTube's own frosted backing, used for the previous and next buttons.
%hook YTFrostedGlassView

- (void)layoutSubviews {
    %orig;
    if (!WTIsInsidePlayer(self)) return;
    for (NSString *key in @[@"_blurEffectView", @"_overlayView"]) ((UIView *)[self valueForKey:key]).alpha = 0;
    UIVisualEffectView *glass = WTGlassBehindContent(self);
    glass.frame = self.bounds;
    glass.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2;
    self.backgroundColor = UIColor.clearColor;
}

%end

%hook YTMainAppControlsOverlayView

- (void)layoutSubviews {
    %orig;
    for (NSString *key in @[@"watchCollapseButton", @"overflowButton", @"closedCaptionsOrSubtitlesButton", @"playbackRouteButton"]) {
        WTAddButtonGlass([self valueForKey:key]);
    }
    WTInstallAutoplayButton([self valueForKey:@"autonavSwitch"]);
}

%end

%hook ABCSwitch

- (void)layoutSubviews {
    %orig;
    UIButton *button = WTAutoplayButton(self);
    if (!button) return;
    for (UIView *subview in self.subviews) subview.hidden = subview != button;
    button.frame = CGRectMake(CGRectGetMidX(self.bounds) - WTPlayerButtonGlassSize / 2,
                              CGRectGetMidY(self.bounds) - WTPlayerButtonGlassSize / 2,
                              WTPlayerButtonGlassSize, WTPlayerButtonGlassSize);
    WTAddCircleGlass(self, WTPlayerButtonGlassSize, CGRectGetMidY(self.bounds));
    WTUpdateAutoplayButton(self);
}

// The button is bigger than YouTube's small control.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIButton *button = WTAutoplayButton(self);
    return (button && CGRectContainsPoint(button.frame, point)) || %orig;
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    WTUpdateAutoplayButton(self);
}

%end

%hook YTReelTopBarView

- (void)layoutSubviews {
    %orig;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:self.subviews];
    while (queue.count) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        if ([view isKindOfClass:%c(YTQTMButton)]) WTAddButtonGlass(view);
        else [queue addObjectsFromArray:view.subviews];
    }
}

%end

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{WTPlayerGlassKey: @YES}];
    if (WTEnabled(WTPlayerGlassKey) && NSClassFromString(@"UIGlassEffect")) %init(WTPlayerGlass);
}
