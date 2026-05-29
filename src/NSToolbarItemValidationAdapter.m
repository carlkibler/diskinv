//
//  NSToolbarItemValidationAdapter.m
//  Disk Inventory X
//
//  GPL v3
//

#import "NSToolbarItemValidationAdapter.h"
#import "Disk_Inventory_Xs-Swift.h"

@implementation NSToolbarItemValidationAdapter

- (void) setToolbarItem: (NSToolbarItem*) toolbarItem
{
	_toolbarItem = toolbarItem;
}

- (void) forwardInvocation: (NSInvocation*) anInvocation
{
	if ( [_toolbarItem respondsToSelector: [anInvocation selector]] )
	{
		[anInvocation setTarget: _toolbarItem];
		[anInvocation invoke];
	}
	else
		[super forwardInvocation: anInvocation];
}

- (NSMethodSignature *) methodSignatureForSelector:(SEL)aSelector
{
	if ( [_toolbarItem respondsToSelector: aSelector] )
		return [_toolbarItem methodSignatureForSelector: aSelector];
	else
		return [super methodSignatureForSelector: aSelector];
}

- (void)setState:(int)itemState
{
	OAToolbarWindowControllerEx *controller = (OAToolbarWindowControllerEx *)[[_toolbarItem toolbar] delegate];

    if ( [controller respondsToSelector:@selector(toolbar:imageForToolbarItem:forState:)] )
    {
        NSImage *image = [controller toolbar: [_toolbarItem toolbar]
                         imageForToolbarItem: _toolbarItem
                                    forState: itemState];

        if ( image != nil && image != [_toolbarItem image] )
            [_toolbarItem setImage: image];
    }
}

@end
