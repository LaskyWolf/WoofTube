#import <UIKit/UIKit.h>
#import "WoofTube.h"

// Swaps YouTube's icons for SF Symbols where they load, so feeds, the player and
// Shorts all change together. YouTube names its icons like yt_outline_bell_24pt
// or ic_fill_shorts_heart_on. A name missing from the table keeps its icon.

static const CGFloat WTSymbolScale = 0.72;

static NSString *WTSymbolForStem(NSString *stem) {
    static NSDictionary<NSString *, NSString *> *symbols;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbols = @{
            @"add": @"plus",
            @"airplay": @"airplayvideo",
            @"arrow_repeat": @"repeat",
            @"arrow_shuffle": @"shuffle",
            @"bell": @"bell",
            @"bookmark": @"bookmark",
            @"bookmark_border": @"bookmark",
            @"cast": @"rectangle.on.rectangle",
            @"check": @"checkmark",
            @"checkmark": @"checkmark",
            @"chevron_down": @"chevron.down",
            @"chevron_left": @"chevron.left",
            @"chevron_right": @"chevron.right",
            @"chevron_up": @"chevron.up",
            @"chromecast": @"rectangle.on.rectangle",
            @"clock": @"clock",
            @"close": @"xmark",
            @"closed_caption": @"captions.bubble",
            @"closed_caption_off": @"captions.bubble",
            @"closed_captions": @"captions.bubble",
            @"comment": @"bubble.left",
            @"dislike": @"hand.thumbsdown",
            @"download": @"arrow.down.circle",
            @"fast_forward": @"forward",
            @"file_download": @"arrow.down.circle",
            @"flag": @"flag",
            @"fullscreen": @"arrow.up.left.and.arrow.down.right",
            @"fullscreen_exit": @"arrow.down.right.and.arrow.up.left",
            @"gear": @"gear",
            @"heart": @"heart",
            @"history": @"clock.arrow.circlepath",
            @"home": @"house",
            @"ios_share": @"square.and.arrow.up",
            @"library": @"rectangle.stack",
            @"like": @"hand.thumbsup",
            @"link": @"link",
            @"message_bubble_empty": @"bubble.left",
            @"message_bubble_left": @"bubble.left",
            @"message_bubble_right": @"bubble.right",
            @"more_horiz": @"ellipsis",
            @"more_vert": @"ellipsis",
            @"notifications": @"bell",
            @"notifications_none": @"bell",
            @"pause": @"pause",
            @"person": @"person",
            @"person_circle": @"person.crop.circle",
            @"picture_in_picture": @"pip",
            @"play": @"play",
            @"play_arrow": @"play",
            @"player_full_enter": @"arrow.up.left.and.arrow.down.right",
            @"player_full_exit_alt": @"arrow.down.right.and.arrow.up.left",
            @"playlist_add": @"text.badge.plus",
            @"remix": @"arrow.triangle.2.circlepath",
            @"repeat": @"repeat",
            @"replay": @"arrow.counterclockwise",
            @"replay_arrow": @"arrow.counterclockwise",
            @"save": @"bookmark",
            @"search": @"magnifyingglass",
            @"settings": @"gear",
            @"share": @"square.and.arrow.up",
            @"share_ios": @"square.and.arrow.up",
            @"shuffle": @"shuffle",
            @"skip5_back": @"gobackward.5",
            @"skip5_forward": @"goforward.5",
            @"skip10_back": @"gobackward.10",
            @"skip10_forward": @"goforward.10",
            @"skip15_back": @"gobackward.15",
            @"skip15_forward": @"goforward.15",
            @"skip30_back": @"gobackward.30",
            @"skip30_forward": @"goforward.30",
            @"skip60_back": @"gobackward.60",
            @"skip60_forward": @"goforward.60",
            @"skip_next": @"forward.end",
            @"skip_previous": @"backward.end",
            @"sparkles": @"sparkles",
            @"subscriptions": @"rectangle.stack.badge.play",
            @"subtitles": @"captions.bubble",
            @"thumb_down": @"hand.thumbsdown",
            @"thumb_up": @"hand.thumbsup",
            @"tune": @"slider.horizontal.3",
            @"volume_mute": @"speaker.slash",
            @"volume_off": @"speaker.slash",
            @"volume_on": @"speaker.wave.2",
            @"volume_up": @"speaker.wave.2",
            @"x": @"xmark",
        };
    });
    return symbols[stem];
}

static NSString *WTStripped(NSString *name, NSString *pattern) {
    return [name stringByReplacingOccurrencesOfString:pattern withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, name.length)];
}

// yt_fill_thumb_up_black_24 becomes thumb_up. Returns nil for names that aren't icons.
static NSString *WTStemForName(NSString *name, BOOL *filled) {
    NSString *stem = name.lastPathComponent;
    if (![stem hasPrefix:@"yt_"] && ![stem hasPrefix:@"ic_"] && ![stem hasPrefix:@"youtube_"]) return nil;
    *filled = [name rangeOfString:@"fill"].location != NSNotFound || [stem hasSuffix:@"_on"];
    stem = WTStripped(stem, @"^(yt_outline_|yt_fill_|ic_outline_|ic_fill_|yt_ic_|ic_|yt_|youtube_)");
    stem = WTStripped(stem, @"^experimental_");
    stem = WTStripped(stem, @"(_cairo)?(_vd_theme|_vd|_black|_white|_grey[0-9]+|_tw|_bold)?(_[0-9]+(pt|dp))?(_[0-9]+)?(_gm)?(_[123]x)?(_Normal)?$");
    stem = WTStripped(stem, @"^(shorts_|reels_|reel_)");
    stem = WTStripped(stem, @"(_colored|_filled|_fill|_outline|_off|_on)?(_style_[a-z])?$");
    return stem;
}

// The icon's average color, so a white or red icon stays white or red.
static UIColor *WTAverageColor(UIImage *image) {
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return UIColor.blackColor;
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    if (!pixel[3]) return UIColor.blackColor;
    CGFloat alpha = pixel[3];
    return [UIColor colorWithRed:MIN(pixel[0] / alpha, 1) green:MIN(pixel[1] / alpha, 1) blue:MIN(pixel[2] / alpha, 1) alpha:1];
}

static UIImage *WTRenderSymbol(NSString *symbol, BOOL filled, UIImage *original) {
    // Playback controls are filled in Apple's players.
    BOOL playback = [symbol isEqualToString:@"play"] || [symbol isEqualToString:@"pause"]
        || [symbol isEqualToString:@"forward.end"] || [symbol isEqualToString:@"backward.end"];
    CGSize size = original.size;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:size.height * WTSymbolScale];
    UIImage *image = (filled || playback) ? [UIImage systemImageNamed:[symbol stringByAppendingString:@".fill"] withConfiguration:configuration] : nil;
    image = image ?: [UIImage systemImageNamed:symbol withConfiguration:configuration];
    if (!image) return nil;
    image = [image imageWithTintColor:WTAverageColor(original) renderingMode:UIImageRenderingModeAlwaysOriginal];

    // Same canvas as the original, so YouTube's layout doesn't move.
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = original.scale;
    UIImage *result = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawAtPoint:CGPointMake((size.width - image.size.width) / 2, (size.height - image.size.height) / 2)];
    }];
    return [result imageWithRenderingMode:original.renderingMode];
}

// The same name can come back tinted differently, so the cache only remembers
// names that have no symbol.
static UIImage *WTSymbolImage(NSString *name, UIImage *original) {
    if (![name isKindOfClass:NSString.class] || !original || original.isSymbolImage) return original;

    static NSCache<NSString *, id> *unmapped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unmapped = [NSCache new];
    });
    if ([unmapped objectForKey:name]) return original;

    BOOL filled = NO;
    NSString *symbol = WTSymbolForStem(WTStemForName(name, &filled));
    UIImage *result = symbol ? WTRenderSymbol(symbol, filled, original) : nil;
    if (!result) [unmapped setObject:NSNull.null forKey:name];
    return result ?: original;
}

// YTIIcon only knows a number. These numbers come from YouTubeHeader's YTIcon.h.
static UIImage *WTSymbolImageForIconType(int type, BOOL selected, UIImage *original) {
    if (!original || original.isSymbolImage) return original;
    NSString *symbol = @{
        @44: @"gear", @48: @"square.and.arrow.up", @51: @"hand.thumbsdown", @60: @"magnifyingglass",
        @160: @"hand.thumbsup", @215: @"xmark", @221: @"chevron.right", @222: @"chevron.left",
        @256: @"plus", @301: @"hand.thumbsup", @386: @"xmark", @560: @"plus", @565: @"bookmark",
        @566: @"bookmark", @886: @"rectangle.on.rectangle", @943: @"magnifyingglass", @1045: @"magnifyingglass",
        @1136: @"plus", @1160: @"magnifyingglass", @1162: @"gear",
    }[@(type)];
    UIImage *result = symbol ? WTRenderSymbol(symbol, selected || type == 301 || type == 565, original) : nil;
    return result ?: original;
}

@interface YTIIcon : NSObject
@property (nonatomic, assign, readwrite) int iconType;
@end

%group WTAppleIcons

// YouTube's own icon loaders. Most icons come through these, not through UIImage.
%hook YTAssetLoader
- (UIImage *)imageNamed:(NSString *)name {
    return WTSymbolImage(name, %orig);
}
%end

%hook QTMIcon
+ (UIImage *)imageWithName:(NSString *)name color:(UIColor *)color {
    return WTSymbolImage(name, %orig);
}
+ (UIImage *)imageWithName:(NSString *)name color:(UIColor *)color bundleId:(NSString *)bundleId {
    return WTSymbolImage(name, %orig);
}
%end

%hook YTIIcon
- (UIImage *)iconImageWithColor:(UIColor *)color {
    return WTSymbolImageForIconType(self.iconType, NO, %orig);
}
- (UIImage *)iconImageWithSelected:(BOOL)selected {
    return WTSymbolImageForIconType(self.iconType, selected, %orig);
}
- (UIImage *)iconImageWithPageStyle:(NSInteger)pageStyle {
    return WTSymbolImageForIconType(self.iconType, NO, %orig);
}
%end

%hook UIImage

+ (UIImage *)imageNamed:(NSString *)name {
    return WTSymbolImage(name, %orig);
}

+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traits {
    return WTSymbolImage(name, %orig);
}

+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle withConfiguration:(UIImageConfiguration *)configuration {
    return WTSymbolImage(name, %orig);
}

%end

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{WTAppleIconsKey: @YES}];
    if (WTEnabled(WTAppleIconsKey)) %init(WTAppleIcons);
}
