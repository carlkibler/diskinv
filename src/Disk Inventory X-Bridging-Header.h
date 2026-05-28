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

// FSItem itself is now a Swift class (FSItem.swift). Its non-class support
// symbols (FSItemType enum, g_fileCount/g_folderCount, exception names, the
// NSString compareAsFilesystemName: category) live in FSItemSupport.h, which
// is macro-clean (Cocoa only) and needed by the Swift FSItem port.
#import "FSItemSupport.h"

// NTFilePasteboardSource.h is macro-clean (no .pch macros, no own imports);
// the Swift FSItem.writeToPasteboard:withTypes: needs the +file:toPasteboard:types: API.
#import "NTFilePasteboardSource.h"

// TMVCushionRenderer.h is macro-clean. Exposed for the Swift FileTypeColors port.
#import "TMVCushionRenderer.h"

// FSItemIndexType.h is macro-clean (Foundation only). Exposes the
// FSItemIndexType NS_OPTIONS bitmask to the Swift FSItemIndex port.
#import "FSItemIndexType.h"

// PreferenceKeys.h is macro-clean (Foundation only). Exposed so the Swift
// Preferences port can reference the extern NSString* key constants.
#import "PreferenceKeys.h"

#endif /* DiskInventoryX_BridgingHeader_h */
