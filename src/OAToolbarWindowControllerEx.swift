//
//  OAToolbarWindowControllerEx.swift
//  Disk Inventory Xs
//
//  Swift port of OAToolbarWindowControllerEx.{h,m}. Adds to the base
//  DIXToolbarWindowController: localized toolbar-item labels/tooltips pulled
//  from the matching menu item, multi-state toolbar images, and toolbar-item
//  validation routed through -validateMenuItem: via NSToolbarItemValidationAdapter
//  (which stays ObjC because it relies on NSInvocation forwarding).
//
//  GPL v3
//

import Cocoa

@objc(OAToolbarWindowControllerEx)
class OAToolbarWindowControllerEx: DIXToolbarWindowController, NSMenuItemValidation {

    private static let validationAdapter = NSToolbarItemValidationAdapter()
    private static let stateImages = NSMutableDictionary()  // configName -> (itemId -> (imageKey -> NSImage))

    // returns an image for a toolbar item in a specific state (on/off/mixed, like a menu item)
    @objc(toolbar:imageForToolbarItem:forState:)
    func toolbar(_ theToolbar: NSToolbar, imageForToolbarItem item: NSToolbarItem, forState state: Int) -> NSImage? {
        let imageKey: String
        switch state {
        case NSControl.StateValue.on.rawValue: imageKey = "imageName"
        case NSControl.StateValue.off.rawValue: imageKey = "imageNameOffState"
        case NSControl.StateValue.mixed.rawValue: imageKey = "imageNameMixedState"
        default: return nil
        }

        let toolbarImageCache: NSMutableDictionary
        if let existing = Self.stateImages[toolbarConfigurationName] as? NSMutableDictionary {
            toolbarImageCache = existing
        } else {
            toolbarImageCache = NSMutableDictionary()
            Self.stateImages[toolbarConfigurationName] = toolbarImageCache
        }

        let itemId = item.itemIdentifier.rawValue
        let itemImageCache: NSMutableDictionary
        if let existing = toolbarImageCache[itemId] as? NSMutableDictionary {
            itemImageCache = existing
        } else {
            itemImageCache = NSMutableDictionary()
            toolbarImageCache[itemId] = itemImageCache
        }

        if let image = itemImageCache[imageKey] as? NSImage {
            return image
        }

        // call super to skip the menu-synchronisation done in our override below
        let itemInfo = super.toolbarInfoForItem(itemId)
        let imageName = (itemInfo?[imageKey] as? String) ?? (itemInfo?["imageName"] as? String)
        guard let imageName = imageName, let image = NSImage(named: imageName) else { return nil }

        itemImageCache[imageKey] = image
        return image
    }

    override func toolbarInfoForItem(_ identifier: String) -> [String: Any]? {
        let itemInfo = NSMutableDictionary(dictionary: super.toolbarInfoForItem(identifier) ?? [:])

        // localize the display strings
        for key in ["label", "paletteLabel", "toolTip"] {
            if let s = itemInfo[key] as? String, !s.isEmpty {
                itemInfo[key] = NSLocalizedString(s, comment: "")
            }
        }

        // ensure the action string ends with ':' (actions take a sender)
        var actionString = itemInfo["action"] as? String
        if let a = actionString, !a.isEmpty, !a.hasSuffix(":") {
            actionString = a + ":"
            itemInfo["action"] = actionString
        }

        // Pull the label/tooltip from the menu item with the same action, so the
        // strings only need to be defined/localized in the menu, not the .toolbar.
        if let a = actionString, !a.isEmpty,
           itemInfo["label"] == nil || itemInfo["toolTip"] == nil {
            let action = NSSelectorFromString(a)
            if let menuItem = NSApp.mainMenu?.menuItem(withAction: action) {
                if itemInfo["label"] == nil, !menuItem.title.isEmpty {
                    itemInfo["label"] = Self.titleByStrippingTrailingDots(menuItem.title)
                }
                if itemInfo["toolTip"] == nil, let tt = menuItem.toolTip, !tt.isEmpty {
                    itemInfo["toolTip"] = tt
                }
            }
        }

        // paletteLabel (the customization-sheet title) falls back to label
        if itemInfo["paletteLabel"] == nil, let label = itemInfo["label"] {
            itemInfo["paletteLabel"] = label
        }

        return itemInfo as? [String: Any]
    }

    // strip trailing periods/whitespace, e.g. "Preferences..." -> "Preferences"
    private static func titleByStrippingTrailingDots(_ title: String) -> String {
        var chars = Array(title)
        var end = chars.count
        while end > 0, let last = chars[0..<end].last, last == "." || last.isWhitespace {
            end -= 1
        }
        return String(chars[0..<end])
    }

    override func toolbar(_ toolbar: NSToolbar,
                          itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let toolbarItem = super.toolbar(toolbar, itemForItemIdentifier: itemIdentifier, willBeInsertedIntoToolbar: flag)

        // we take labels/tooltips from the menu item, so we don't use a toolbar
        // .strings file; just make sure the tooltip is set
        if toolbarItem?.toolTip == nil,
           let toolTip = toolbarInfoForItem(itemIdentifier.rawValue)?["toolTip"] as? String {
            toolbarItem?.toolTip = toolTip
        }

        return toolbarItem
    }

    // KVC targets a toolbar item's "target" property can resolve to
    @objc var documentController: NSDocumentController { NSDocumentController.shared }
    @objc var application: NSApplication { NSApp }

    // base impl; MainWindowController overrides with the real validation logic
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    @objc func validateToolbarItem(_ theItem: NSToolbarItem) -> Bool {
        guard window?.isKeyWindow == true else { return false }

        Self.validationAdapter.setToolbarItem(theItem)
        // the adapter masquerades as the menu item being validated (it forwards
        // unknown selectors to the toolbar item)
        return validateMenuItem(unsafeBitCast(Self.validationAdapter, to: NSMenuItem.self))
    }
}

extension NSMenu {
    // linear (recursive) search for a menu item with the given action
    @objc(menuItemWithAction:)
    func menuItem(withAction action: Selector) -> NSMenuItem? {
        var i = numberOfItems
        while i > 0 {
            i -= 1
            guard let item = self.item(at: i) else { continue }
            if item.action == action { return item }
            if item.hasSubmenu, let found = item.submenu?.menuItem(withAction: action) {
                return found
            }
        }
        return nil
    }
}
