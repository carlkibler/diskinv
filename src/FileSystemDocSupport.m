//
//  FileSystemDocSupport.m
//  Disk Inventory X
//
//  Definitions for the KVO key and notification name constants declared
//  in FileSystemDocSupport.h. Values copied verbatim from the original
//  FileSystemDoc.m during the Swift port of FileSystemDoc.
//
//  GPL v3
//

#import "FileSystemDocSupport.h"

/* keys for Key Value Observing (KVO) */
NSString *DocKeySelectedItem = @"selectedItem";

/* FileSystemDoc Notifications */
NSString *GlobalSelectionChangedNotification = @"GlobalSelectionChanged";
NSString *ZoomedItemChangedNotification = @"ZoomedItemChanged";
NSString *FSItemsChangedNotification = @"FSItemsChanged";
NSString *ViewOptionChangedNotification = @"ViewOptionsChangedNotification";
NSString *ChangedViewOption = @"ChangedViewOption";
NSString *NewItem = @"NewItem";
NSString *OldItem = @"OldItem";
