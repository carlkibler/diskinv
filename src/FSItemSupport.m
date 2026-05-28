//
//  FSItemSupport.m
//  Disk Inventory X
//
//  Definitions for the non-class support symbols declared in
//  FSItemSupport.h. Extracted from the original FSItem.m during the
//  Swift port of FSItem.
//
//  GPL v3
//

#import "FSItemSupport.h"

//for debugging and logging purposes
unsigned g_fileCount;
unsigned g_folderCount;

@implementation NSString (ComparisonAdditions)
- (NSComparisonResult) compareAsFilesystemName: (NSString*) other
{
	return [self compare: other options: (NSNumericSearch | NSCaseInsensitiveSearch)];
}
@end
