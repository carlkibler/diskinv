/* FileKindsTableController */

#import <Cocoa/Cocoa.h>
@class FileSystemDoc;
#import "MainWindowController.h"

@interface FileKindsTableController : NSObject
{
    IBOutlet NSTableView *_tableView;
    IBOutlet MainWindowController *_windowController;
	IBOutlet NSArrayController *_kindsPopupArrayController;
	IBOutlet NSArrayController *_kindsTableArrayController;

    NSMutableDictionary *_cushionImages;
}

- (FileSystemDoc*) document;

- (IBAction) showFilesInSelectionList: (id) sender;

@end
