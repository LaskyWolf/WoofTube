#import "WTSettingsViewController.h"
#import "WoofTube.h"

// One table section of switches. Add a section or a row here to add a setting.
static NSArray<NSDictionary *> *WTSections(void) {
    return @[
        @{
            @"header": @"Top Bar",
            @"footer": @"Changes apply the next time the top bar redraws, for example after you switch tabs.",
            @"rows": @[
                @{@"title": @"Hide Cast Button", @"key": WTHideCastKey},
            ],
        },
    ];
}

@implementation WTSettingsViewController {
    NSArray<NSDictionary *> *_sections;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _sections = WTSections();
        self.title = @"WoofTube";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section][@"header"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[section][@"footer"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _sections[indexPath.section][@"rows"][indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"switch"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"switch"];

    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = row[@"title"];
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = WTEnabled(row[@"key"]);
    toggle.accessibilityIdentifier = row[@"key"];
    [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)toggled:(UISwitch *)toggle {
    [[NSUserDefaults standardUserDefaults] setBool:toggle.on forKey:toggle.accessibilityIdentifier];
}

@end
