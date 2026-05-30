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

// FSItem itself is now a Swift class (FSItem.swift). Its non-class support
// symbols (FSItemType enum, g_fileCount/g_folderCount, exception names, the
// NSString compareAsFilesystemName: category) live in FSItemSupport.h, which
// is macro-clean (Cocoa only) and needed by the Swift FSItem port.
#import "FSItemSupport.h"

// FSItemIndexType.h is macro-clean (Foundation only). Exposes the
// FSItemIndexType NS_OPTIONS bitmask to the Swift FSItemIndex port.
#import "FSItemIndexType.h"

// FileSystemDocSupport.h is macro-clean (Foundation only). Holds the KVO
// key and notification-name extern NSString* constants needed by the Swift
// FileSystemDoc port (extern C string constants cannot live in Swift).
#import "FileSystemDocSupport.h"

// Timing.h is a pure-C stopwatch (stdint only). The Swift LoadingPanelController
// uses getTime()/subtractTime() to throttle its event-loop pumping.
#import "Timing.h"

#endif /* DiskInventoryX_BridgingHeader_h */
