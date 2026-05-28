/* TreeMapViewController */

#import <Cocoa/Cocoa.h>
@class FileSystemDoc;
@class FSItem;

@interface TreeMapViewController : NSObject
{
    IBOutlet id _fileNameTextField;
    IBOutlet id _fileSizeTextField;
    IBOutlet id _treeMapView;
    IBOutlet FileSystemDoc *_document;
	
	FSItem *_otherSpaceItem;
	FSItem *_freeSpaceItem;
}

- (FileSystemDoc*) document;

- (FSItem*) rootItem;

@end
