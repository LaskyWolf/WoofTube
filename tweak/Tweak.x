#import <YouTubeHeader/YTRightNavigationButtons.h>
#import "WoofTube.h"

// Top bar: Cast button.
// YouTube tags the button with this identifier in every recent version.
%hook YTRightNavigationButtons

- (void)layoutSubviews {
    %orig;
    for (UIView *button in self.subviews) {
        if ([button.accessibilityIdentifier isEqualToString:@"id.mdx.playbackroute.button"])
            button.hidden = WTEnabled(WTHideCastKey);
    }
}

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        WTHideCastKey: @YES,
    }];
}
