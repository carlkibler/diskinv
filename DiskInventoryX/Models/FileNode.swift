//
//  FileNode.swift
//  DiskInventoryX
//
//  File system node representing a file or folder
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum FileNodeType: Equatable {
    case regular
    case otherSpace
    case unscannedSpace
    case freeSpace
    case summary
    case incompleteSummary
}

class FileNode: Identifiable {
    /// Object identity is unique for the lifetime of a node and avoids allocating
    /// and storing a UUID for every item in a scan.
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    var size: UInt64
    let type: FileNodeType

    weak var parent: FileNode?
    var children: [FileNode] = []

    // Lazily computed properties
    private var _kindName: String?
    private var _icon: NSImage?

    // MARK: - Initialization

    init(url: URL, name: String? = nil, isDirectory: Bool = false, isPackage: Bool = false,
         size: UInt64 = 0, type: FileNodeType = .regular) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.type = type
    }

    // MARK: - Computed Properties

    var kindName: String {
        if let cached = _kindName {
            return cached
        }

        switch type {
        case .otherSpace:
            _kindName = "Other Space"
        case .unscannedSpace:
            _kindName = "Not Scanned"
        case .freeSpace:
            _kindName = "Free Space"
        case .summary:
            _kindName = "Summarized Items"
        case .incompleteSummary:
            _kindName = "Incomplete Scan"
        case .regular:
            if isDirectory && !isPackage {
                _kindName = "Folder"
            } else if let utType = utType {
                _kindName = utType.localizedDescription ?? utType.identifier
            } else {
                _kindName = "Document"
            }
        }

        return _kindName ?? "Unknown"
    }

    var utType: UTType? {
        guard type == .regular else { return nil }
        if isDirectory && !isPackage {
            return .folder
        }
        return UTType(filenameExtension: url.pathExtension) ?? .data
    }

    var icon: NSImage {
        if let cached = _icon {
            return cached
        }

        switch type {
        case .freeSpace:
            _icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Free Space")
                ?? NSImage(named: NSImage.folderName)!
        case .otherSpace:
            _icon = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: "Other Space")
                ?? NSImage(named: NSImage.folderName)!
        case .unscannedSpace:
            _icon = NSImage(systemSymbolName: "exclamationmark.folder", accessibilityDescription: "Not Scanned")
                ?? NSImage(named: NSImage.folderName)!
        case .summary:
            _icon = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Summarized Items")
                ?? NSImage(named: NSImage.folderName)!
        case .incompleteSummary:
            _icon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Incomplete Scan")
                ?? NSImage(named: NSImage.folderName)!
        case .regular:
            _icon = NSWorkspace.shared.icon(forFile: url.path)
        }

        _icon?.size = NSSize(width: 16, height: 16)
        return _icon ?? NSImage(named: NSImage.folderName)!
    }

    var displayPath: String {
        var components: [String] = []
        var current: FileNode? = self

        while let node = current {
            components.insert(node.name, at: 0)
            current = node.parent
        }

        return components.joined(separator: "/")
    }

    var isSpecialItem: Bool {
        type != .regular
    }

    func containsNode(where predicate: (FileNode) -> Bool) -> Bool {
        predicate(self) || children.contains { $0.containsNode(where: predicate) }
    }

    // MARK: - Tree Operations

    func findNode(at path: [String]) -> FileNode? {
        guard !path.isEmpty else { return self }

        let targetName = path[0]
        guard let child = children.first(where: { $0.name == targetName }) else {
            return nil
        }

        if path.count == 1 {
            return child
        }

        return child.findNode(at: Array(path.dropFirst()))
    }

    func pathFromRoot() -> [FileNode] {
        var path: [FileNode] = [self]
        var current = parent

        while let node = current {
            path.insert(node, at: 0)
            current = node.parent
        }

        return path
    }

    func sortChildrenBySize() {
        children.sort { $0.size > $1.size }
        for child in children where child.isDirectory {
            child.sortChildrenBySize()
        }
    }

    func recalculateSize() {
        if isDirectory {
            size = children.reduce(0) { $0 + $1.size }
        }
    }
}

// MARK: - Hashable

extension FileNode: Hashable {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - CustomStringConvertible

extension FileNode: CustomStringConvertible {
    var description: String {
        "\(name) (\(FileSizeFormatter.string(from: size)))"
    }
}
