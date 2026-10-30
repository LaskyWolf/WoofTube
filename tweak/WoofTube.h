#import <Foundation/Foundation.h>

// NSUserDefaults keys. Defaults are registered in Tweak.x.
#define WTHideCastKey @"WoofTube.HideCast"

static inline BOOL WTEnabled(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
