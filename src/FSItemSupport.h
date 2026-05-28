//
//  FSItemSupport.h
//  Disk Inventory X
//
//  Non-class support declarations extracted from the original FSItem.h
//  so that they remain available to ObjC callers (and to Swift, via the
//  bridging header) after FSItem itself was ported to Swift.
//
//  Macro-clean: depends only on Cocoa, so it is safe to expose to Swift
//  through the (non-precompiled) bridging header.
//
//  GPL v3
//

#import <Cocoa/Cocoa.h>

//for debugging and logging purposes
extern unsigned g_fileCount;
extern unsigned g_folderCount;

//Exceptions raised by FSItem
//delegate canceled the loading
extern NSString* FSItemLoadingCanceledException;
//error while enumerating files/folders (e.g. volume has been ejected (unmounted))
extern NSString* FSItemLoadingFailedException;

typedef enum
{
	FileFolderItem, //regular file or folder
	OtherSpaceItem, //represents "other" space (that means the space occupied by the rest of the files on the volume)
	FreeSpaceItem	//free space on volume
} FSItemType;

@interface NSString (ComparisonAdditions)
- (NSComparisonResult) compareAsFilesystemName: (NSString*) other;
@end
