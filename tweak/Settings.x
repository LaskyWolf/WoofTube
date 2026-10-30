#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import "WTSettingsViewController.h"

// Adds a "WoofTube" group to YouTube's settings with one row that opens
// the native settings screen as a sheet.

// Group and category IDs YouTube does not use.
static const NSUInteger WTSettingsGroup = 0x57544752;
static const NSInteger WTSettingsCategory = 0x57544643;

@interface YTSettingsSectionItemManager (WoofTube)
- (void)updateWoofTubeSectionWithEntry:(id)entry;
@end

// Grouped settings layout (current YouTube versions): YouTube builds one
// YTSettingsGroupData per group type, so WoofTube adds its own group on top.
%hook YTAppSettingsGroupPresentationData

+ (NSArray *)orderedGroups {
    YTSettingsGroupData *group = [[%c(YTSettingsGroupData) alloc] initWithGroupType:WTSettingsGroup];
    return group ? [@[group] arrayByAddingObjectsFromArray:%orig] : %orig;
}

%end

%hook YTSettingsGroupData

- (NSString *)titleForSettingGroupType:(NSUInteger)groupType {
    return groupType == WTSettingsGroup ? @"WoofTube" : %orig;
}

- (NSArray<NSNumber *> *)orderedCategoriesForGroupType:(NSUInteger)groupType {
    return groupType == WTSettingsGroup ? @[@(WTSettingsCategory)] : %orig;
}

%end

// Flat settings layout (older YouTube versions).
%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray<NSNumber *> *order = %orig;
    NSUInteger general = [order indexOfObject:@(1)];
    if (general == NSNotFound) return order;
    NSMutableArray *newOrder = [order mutableCopy];
    [newOrder insertObject:@(WTSettingsCategory) atIndex:general + 1];
    return newOrder;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateWoofTubeSectionWithEntry:(id)entry {
    YTSettingsViewController *settings = [self valueForKey:@"_settingsViewControllerDelegate"];

    YTSettingsSectionItem *open = [%c(YTSettingsSectionItem) itemWithTitle:@"WoofTube Settings"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger index) {
            UINavigationController *sheet = [[UINavigationController alloc]
                initWithRootViewController:[WTSettingsViewController new]];
            sheet.navigationBar.prefersLargeTitles = YES;
            [settings presentViewController:sheet animated:YES completion:nil];
            return YES;
        }];

    NSMutableArray *items = [NSMutableArray arrayWithObject:open];
    if ([settings respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [settings setSectionItems:items forCategory:WTSettingsCategory title:@"WoofTube" icon:nil titleDescription:nil headerHidden:NO];
    else
        [settings setSectionItems:items forCategory:WTSettingsCategory title:@"WoofTube" titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == WTSettingsCategory) {
        [self updateWoofTubeSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end
