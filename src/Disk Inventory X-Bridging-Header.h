//
//  Disk Inventory X-Bridging-Header.h
//
//  Exposes ObjC declarations to Swift code in this target.
//
//  IMPORTANT: this header is NOT precompiled with the project's .pch, so
//  it cannot transitively pull in headers that depend on the .pch's
//  macros (OBPRECONDITION, OBASSERT, LOG). Only add #imports as Swift
//  code starts to need them — and only headers whose dependency cone is
//  clean of .pch-only symbols.
//

#ifndef DiskInventoryX_BridgingHeader_h
#define DiskInventoryX_BridgingHeader_h

#import <Cocoa/Cocoa.h>

// NSURL-Extensions.h has a clean dependency cone (Foundation only, no .pch
// macros), so it is safe to expose to Swift here. Used by the volume
// transformers.
#import "NSURL-Extensions.h"

// FSItem.h and TMVCushionRenderer.h are macro-clean (FSItem was de-Carbonized:
// UInt64 -> uint64_t). Exposed for the Swift FileTypeColors port.
#import "FSItem.h"
#import "TMVCushionRenderer.h"

// PreferenceKeys.h is macro-clean (Foundation only). Exposed so the Swift
// Preferences port can reference the extern NSString* key constants.
#import "PreferenceKeys.h"

#endif /* DiskInventoryX_BridgingHeader_h */
