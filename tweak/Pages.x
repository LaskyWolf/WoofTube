#import <YouTubeHeader/YTRightNavigationButtons.h>
#import <objc/runtime.h>
#import "WoofTube.h"

// Page styling taken from Woof Music: pure black backgrounds, the system font, a
// large page title instead of the logo, and glass circles for top bar buttons.

@interface YTCommonColorPalette : NSObject
- (NSInteger)pageStyle;
@end

@interface YTNavigationBarTitleView : UIView
@end

static const NSInteger WTDarkPageStyle = 1;
static const void *WTPageTitleKey = &WTPageTitleKey;

static UIFontWeight WTWeightForFontName(NSString *name) {
    if ([name containsString:@"Black"] || [name containsString:@"ExtraBold"]) return UIFontWeightHeavy;
    if ([name containsString:@"Bold"]) return UIFontWeightBold;
    if ([name containsString:@"SemiBold"] || [name containsString:@"Semibold"]) return UIFontWeightSemibold;
    if ([name containsString:@"Medium"]) return UIFontWeightMedium;
    if ([name containsString:@"Light"]) return UIFontWeightLight;
    return UIFontWeightRegular;
}

static BOOL WTIsYouTubeFont(NSString *name) {
    return [name hasPrefix:@"YouTubeSans"] || [name hasPrefix:@"YTSans"]
        || [name hasPrefix:@"Roboto-"] || [name isEqualToString:@"Roboto"];
}

%group WTPages

%hook YTCommonColorPalette
- (UIColor *)background1 { return self.pageStyle == WTDarkPageStyle ? UIColor.blackColor : %orig; }
- (UIColor *)baseBackground { return self.pageStyle == WTDarkPageStyle ? UIColor.blackColor : %orig; }
- (UIColor *)brandBackgroundSolid { return self.pageStyle == WTDarkPageStyle ? UIColor.blackColor : %orig; }
- (UIColor *)brandBackgroundPrimary { return self.pageStyle == WTDarkPageStyle ? UIColor.blackColor : %orig; }
- (UIColor *)generalBackgroundA { return self.pageStyle == WTDarkPageStyle ? UIColor.blackColor : %orig; }
%end

%hook UIFont

+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    if (WTIsYouTubeFont(name)) return [UIFont systemFontOfSize:size weight:WTWeightForFontName(name)];
    return %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    NSString *name = descriptor.postscriptName;
    if (WTIsYouTubeFont(name)) return [UIFont systemFontOfSize:size ?: descriptor.pointSize weight:WTWeightForFontName(name)];
    return %orig;
}

%end

// Pages with a logo are the tabs' root pages. Others have their own title.
%hook YTNavigationBarTitleView

- (void)layoutSubviews {
    %orig;
    UIView *logo = [self valueForKey:@"customView"];
    UILabel *label = objc_getAssociatedObject(self, WTPageTitleKey);
    if (!logo || !self.window) {
        label.hidden = YES;
        return;
    }
    NSString *title = WTCurrentTabTitle();
    if (!title.length) return;

    if (!label) {
        label = [UILabel new];
        UIFontDescriptor *descriptor = [[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleLargeTitle] fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
        label.font = [UIFont fontWithDescriptor:descriptor size:0];
        label.adjustsFontForContentSizeCategory = YES;
        label.adjustsFontSizeToFitWidth = YES;
        label.textColor = UIColor.labelColor;
        [self addSubview:label];
        objc_setAssociatedObject(self, WTPageTitleKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    logo.hidden = YES;
    label.hidden = NO;
    label.text = title;
    self.clipsToBounds = NO;
    CGFloat x = CGRectGetMinX(logo.frame);
    label.frame = CGRectMake(x, 0, CGRectGetWidth(self.bounds) - x, CGRectGetHeight(self.bounds));
}

%end

%hook YTRightNavigationButtons

- (void)layoutSubviews {
    %orig;
    for (UIView *button in self.subviews) {
        if ([button isKindOfClass:%c(YTQTMButton)]) WTAddButtonGlass(button);
    }
}

%end

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{WTPagesKey: @YES}];
    if (WTEnabled(WTPagesKey)) %init(WTPages);
}
