#import "WTSearchResultsController.h"

@implementation WTSearchResultsController {
    NSArray<NSString *> *_suggestions;
    NSURLSessionDataTask *_task;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text;
    [_task cancel];
    if (!text.length) {
        [self showSuggestions:@[]];
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://suggestqueries.google.com/complete/search"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"firefox"],
        [NSURLQueryItem queryItemWithName:@"ds" value:@"yt"],
        [NSURLQueryItem queryItemWithName:@"oe" value:@"utf-8"],
        [NSURLQueryItem queryItemWithName:@"q" value:text],
    ];
    __weak WTSearchResultsController *weakSelf = self;
    _task = [NSURLSession.sharedSession dataTaskWithURL:components.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) return;
        // The response looks like ["query", ["suggestion", "suggestion"]].
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSArray.class] || [json count] < 2 || ![json[1] isKindOfClass:NSArray.class]) return;
        NSArray *suggestions = [json[1] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) {
            return [value isKindOfClass:NSString.class];
        }]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf showSuggestions:suggestions];
        });
    }];
    [_task resume];
}

- (void)showSuggestions:(NSArray<NSString *> *)suggestions {
    _suggestions = suggestions;
    [self.tableView reloadData];
}

- (void)submit:(NSString *)query {
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return;
    if (self.onSubmit) self.onSubmit(query);
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self submit:searchBar.text];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _suggestions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"suggestion"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"suggestion"];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = _suggestions[indexPath.row];
    content.image = [UIImage systemImageNamed:@"magnifyingglass"];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self submit:_suggestions[indexPath.row]];
}

@end
