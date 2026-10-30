#import <Foundation/Foundation.h>
#import <Security/Security.h>

// YouTube's Google sign-in code stores its tokens in Google's shared keychain
// group, which a sideloaded app cannot access. These hooks point it at the
// keychain group the app's own signature allows, so sign-in can be stored.

// Asks iOS which group this app's keychain items go to, using a dummy item.
static NSString *WTAccessGroup(void) {
    static NSString *accessGroup;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"WoofTubeAccessGroupProbe",
            (__bridge id)kSecAttrService: @"WoofTube",
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecItemNotFound)
            status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result) {
            NSDictionary *attributes = CFBridgingRelease(result);
            accessGroup = attributes[(__bridge id)kSecAttrAccessGroup];
        }
    });
    return accessGroup;
}

%hook SSOKeychainHelper
+ (NSString *)accessGroup { return WTAccessGroup() ?: %orig; }
+ (NSString *)sharedAccessGroup { return WTAccessGroup() ?: %orig; }
%end

%hook SSOKeychainCore
+ (NSString *)accessGroup { return WTAccessGroup() ?: %orig; }
+ (NSString *)sharedAccessGroup { return WTAccessGroup() ?: %orig; }
%end

%hook UICKeyChainStore
- (NSString *)accessGroup { return WTAccessGroup() ?: %orig; }
%end
