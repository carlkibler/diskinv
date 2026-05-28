/*
 *  PreferenceKeys.h
 *  Disk Inventory X
 *
 *  Created by Tjark Derlien on 24.11.04.
 *  Copyright 2004 Tjark Derlien. All rights reserved.
 *
 *  Bare extern NSString* preference-key constants. Kept in ObjC (not Swift)
 *  because Swift cannot emit C extern globals and several KVO observers rely
 *  on these as stable `context ==` pointers. Macro-clean (Foundation only) so
 *  it is safe to expose to Swift via the bridging header.
 */

#import <Foundation/Foundation.h>

//keys for preference values
extern NSString *ShowPackageContents;
extern NSString *ShowFreeSpace;
extern NSString *ShowOtherSpace;
extern NSString *IgnoreCreatorCode;
extern NSString *ShowPhysicalFileSize; //logical size otherwise (like the Finder)
extern NSString *UseSmallFontInKindStatistic;
extern NSString *UseSmallFontInFilesView;
extern NSString *UseSmallFontInSelectionList;
extern NSString *SplitWindowHorizontally;
extern NSString *AnimatedZooming;
extern NSString *EnableLogging;
extern NSString *DontShowDonationMessage;
extern NSString *DontShowPrivacyWarningMessage;
extern NSString *ShareKindColors;
