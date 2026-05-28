/* FilesOutlineViewController */

#import <Cocoa/Cocoa.h>
@class FileSystemDoc;
@class FSItem;
#import "ImageAndTextCell.h"
#import "DIXOutlineView.h"

@interface FilesOutlineViewController : NSObject
{
    IBOutlet FileSystemDoc *_document;
    IBOutlet DIXOutlineView *_outlineView;
    IBOutlet NSMenu *_contextMenu;
}

- (FileSystemDoc*) document;

- (FSItem*) rootItem;

@end
