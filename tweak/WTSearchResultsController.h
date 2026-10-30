#import <UIKit/UIKit.h>

// The results list of a UISearchController: YouTube's search suggestions in a
// plain table.
@interface WTSearchResultsController : UITableViewController <UISearchBarDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) void (^onSubmit)(NSString *query);
@end
