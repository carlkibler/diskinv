//
//  FileSystemDocSupport.h
//  Disk Inventory X
//
//  Non-class support declarations extracted from the original
//  FileSystemDoc.h so that they remain available to ObjC callers (and to
//  Swift, via the bridging header) after FileSystemDoc itself was ported
//  to Swift.
//
//  These are the KVO key and the notification name constants. They must
//  remain real ObjC externs because controllers reference them by name
//  (KVO key path "selectedItem", NSNotificationCenter observers) and
//  extern C string constants cannot be defined in Swift.
//
//  Macro-clean: depends only on Foundation, so it is safe to expose to
//  Swift through the (non-precompiled) bridging header.
//
//  GPL v3
//

#import <Foundation/Foundation.h>

/* keys for Key Value Observing (KVO) */
extern NSString *DocKeySelectedItem;

/* FileSystemDoc Notifications */
extern NSString *GlobalSelectionChangedNotification; //userInfo contains new and old selection
extern NSString *ZoomedItemChangedNotification; //userInfo contains new and old zoomed item
extern NSString *FSItemsChangedNotification; //some items are modified, deleted or added; userInfo is nil
extern NSString *ViewOptionChangedNotification; //the name of the changed option is stored in userInfo for key ChangedViewOption (see next line)
extern NSString *ChangedViewOption;
extern NSString *NewItem;
extern NSString *OldItem;

//
// g_EnableLogging is the app-wide logging flag read by the LOG(...) macro in
// the project .pch (which declares `extern BOOL g_EnableLogging;`). Its
// definition lived in MyDocumentController.m; when that class was ported to
// Swift the C global was relocated here (an existing ObjC "support" .m that
// already holds extern globals) so the .pch's extern keeps resolving at link
// time. Swift can't cleanly assign a C `extern BOOL`, so it sets the flag at
// launch via this @objc class method instead.
//
@interface DIXLogging : NSObject
+ (void) updateGlobalLoggingFlag: (BOOL) enabled NS_SWIFT_NAME(updateGlobalLoggingFlag(_:));
@end
