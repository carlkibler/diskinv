//
//  NSToolbarItemValidationAdapter.h
//  Disk Inventory X
//
//  Extracted from OAToolbarWindowControllerEx so it can stay in Objective-C
//  while the controllers move to Swift. It is a message-forwarding proxy
//  (forwardInvocation:/methodSignatureForSelector:) that makes a toolbar item
//  look like a menu item to -validateMenuItem:, intercepting -setState: to swap
//  the toolbar item's multi-state image. NSInvocation forwarding is unavailable
//  in Swift, so this proxy must remain ObjC.
//
//  GPL v3
//

#import <Cocoa/Cocoa.h>

@interface NSToolbarItemValidationAdapter : NSObject
{
	NSToolbarItem* _toolbarItem;
}

- (void) setToolbarItem: (NSToolbarItem*) toolbarItem;
- (void) forwardInvocation: (NSInvocation*) anInvocation;

@end
