#import <Foundation/Foundation.h>

@class UIView;

// NSUserDefaults keys. Each feature's file registers its default.
#define WTHideCastKey @"WoofTube.HideCast"
#define WTNativeTabBarKey @"WoofTube.NativeTabBar"
#define WTHideTabKeyPrefix @"WoofTube.HideTab."
#define WTAppleIconsKey @"WoofTube.AppleIcons"
#define WTPlayerGlassKey @"WoofTube.PlayerGlass"
#define WTPagesKey @"WoofTube.Pages"

// A circle of iOS glass behind a button's icon. Player.x.
void WTAddButtonGlass(UIView *button);
// The title of the tab YouTube is showing. TabBar.x.
NSString *WTCurrentTabTitle(void);

static inline BOOL WTEnabled(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
