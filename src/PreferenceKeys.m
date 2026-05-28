/*
 *  PreferenceKeys.m
 *  Disk Inventory X
 *
 *  Created by Tjark Derlien on 24.11.04.
 *  Copyright 2004 Tjark Derlien. All rights reserved.
 *
 *  Definitions of the preference-key constants. Defining them here preserves
 *  pointer identity for the KVO `context ==` comparison sites.
 */

#import "PreferenceKeys.h"

//keys for preference values
NSString *ShowPackageContents			= @"ShowPackageContents";
NSString *ShowFreeSpace					= @"ShowFreeSpace";
NSString *ShowOtherSpace				= @"ShowOtherSpace";
NSString *IgnoreCreatorCode				= @"IgnoreCreatorCode";
NSString *ShowPhysicalFileSize			= @"ShowPhysicalFileSize"; //logical size otherwise (like the Finder)
NSString *UseSmallFontInKindStatistic	= @"UseSmallFontInKindStatisticView";
NSString *UseSmallFontInFilesView		= @"UseSmallFontInFilesView";
NSString *UseSmallFontInSelectionList	= @"UseSmallFontInSelectionList";
NSString *SplitWindowHorizontally		= @"SplitWindowHorizontally";
NSString *AnimatedZooming				= @"AnimatedZooming";
NSString *EnableLogging					= @"EnableLogging";
NSString *DontShowDonationMessage        = @"DontShowDonationMessage";
NSString *DontShowPrivacyWarningMessage        = @"DontShowPrivacyWarningMessage";
NSString *ShareKindColors				= @"ShareKindColors";
