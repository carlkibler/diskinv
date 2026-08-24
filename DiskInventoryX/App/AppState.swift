//
//  AppState.swift
//  DiskInventoryX
//
//  Global application state management
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    @Published var rootNode: FileNode?
    @Published var zoomedNode: FileNode?
    @Published var selectedNode: FileNode?
    @Published var selectedNodes: Set<FileNode> = []
    @Published var zoomStack: [FileNode] = []

    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    @Published var errorMessage: String?
    @Published var trashProtectionMessage: String?
    @Published var pendingTrashNodes: [FileNode] = []

    @Published var kindStatistics: [FileKindStatistic] = []
    @Published var selectedKind: String?

    // MARK: - Settings

    @AppStorage("showPhysicalSize") var showPhysicalSize = false
    @AppStorage("showPackageContents") var showPackageContents = false
    @AppStorage("ignoreCreatorCodes") var ignoreCreatorCodes = true
    @AppStorage("showFreeSpace") var showFreeSpace = true
    @AppStorage("showOtherSpace") var showOtherSpace = true

    // MARK: - Private

    private var scanner: FileScanner?
    private var colorAssigner = FileKindColorAssigner()
    private var hasExplainedProtectedFolders = false

    // MARK: - Computed Properties

    var displayRoot: FileNode? {
        zoomedNode ?? rootNode
    }

    // MARK: - Actions

    func showOpenPanel() {
        guard !isScanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to analyze disk usage"
        panel.prompt = "Analyze"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await scan(url: url)
            }
        }
    }

    func scan(url: URL) async {
        // Cancel any existing scan
        await scanner?.cancel()

        isScanning = true
        scanProgress = ScanProgress(currentFolder: url.lastPathComponent, filesScanned: 0, foldersScanned: 0)
        errorMessage = nil
        rootNode = nil
        zoomedNode = nil
        zoomStack = []
        selectedNode = nil
        selectedNodes = []
        kindStatistics = []

        let newScanner = FileScanner()
        scanner = newScanner

        do {
            let root = try await newScanner.scan(
                url: url,
                showPackageContents: showPackageContents,
                usePhysicalSize: showPhysicalSize,
                mainDiskOnly: url.standardizedFileURL.path == "/"
            ) { [weak self] folder, files, folders in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(
                        currentFolder: folder,
                        filesScanned: files,
                        foldersScanned: folders
                    )
                }
            }

            try await calculateStatistics(for: root)
            rootNode = root

            // Add free space and other space items if scanning a volume root
            if showFreeSpace || showOtherSpace {
                await addVolumeSpaceItems(for: url)
            }

        } catch is CancellationError {
            // Scan was cancelled, ignore
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
        scanProgress = nil
    }

    func scanPreset(url: URL) async {
        let protectedFolders = protectedFoldersWithin(url)
        if !protectedFolders.isEmpty {
            if !hasExplainedProtectedFolders {
                let alert = NSAlert()
                alert.messageText = "Folder Access Required"
                alert.informativeText = "macOS may ask for access to Desktop, Documents, and Downloads. Approve each request now so the scan can include them. Some system data requires Full Disk Access in System Settings."
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                hasExplainedProtectedFolders = true
            }

            for folder in protectedFolders {
                _ = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
            }
        }

        await scan(url: url)
    }

    func refresh() async {
        guard let root = rootNode else { return }
        await scan(url: root.url)
    }

    func zoomIn() {
        guard let selected = selectedNode, selected.isDirectory else { return }

        if let current = zoomedNode {
            zoomStack.append(current)
        } else if let root = rootNode {
            zoomStack.append(root)
        }

        zoomedNode = selected
    }

    func zoomOut() {
        guard !zoomStack.isEmpty else { return }
        zoomedNode = zoomStack.removeLast()

        if zoomedNode === rootNode {
            zoomedNode = nil
        }
    }

    func zoomToRoot() {
        zoomedNode = nil
        zoomStack = []
    }

    func requestMoveSelectedToTrash() {
        let nodes = selectedNodes.isEmpty ? [selectedNode].compactMap { $0 } : Array(selectedNodes)
        requestMoveToTrash(nodes)
    }

    func requestMoveToTrash(_ nodes: [FileNode]) {
        let candidates = nodes
            .filter { !$0.isSpecialItem }
            .sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
        var nodes: [FileNode] = []
        for candidate in candidates {
            let path = candidate.url.standardizedFileURL.path
            if !nodes.contains(where: {
                let parentPath = $0.url.standardizedFileURL.path
                return path.hasPrefix(parentPath + "/")
            }) {
                nodes.append(candidate)
            }
        }
        guard !nodes.isEmpty else { return }
        guard let protectedNode = nodes.first(where: {
            isProtectedFromTrash($0.url, isDirectory: $0.isDirectory)
        }) else {
            pendingTrashNodes = nodes.sorted { $0.displayPath < $1.displayPath }
            return
        }

        trashProtectionMessage = "\(protectedNode.name) is a top-level or system folder. Removing it here is too dangerous, so Disk Inventory X-Ray will not enable that action."
    }

    func confirmMoveToTrash() {
        let nodes = pendingTrashNodes
        pendingTrashNodes = []
        guard !nodes.isEmpty else { return }
        let nextSelection = nextSelection(afterDeleting: Set(nodes))
        let urls = nodes.map(\.url)

        Task {
            do {
                try await Task.detached(priority: .utility) {
                    for url in urls {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }.value

                for node in nodes {
                    node.parent?.children.removeAll { $0 === node }
                }

                var ancestors = Set(nodes.compactMap(\.parent))
                while !ancestors.isEmpty {
                    let currentLevel = ancestors
                    ancestors.removeAll()
                    for node in currentLevel {
                        node.recalculateSize()
                        if let parent = node.parent {
                            ancestors.insert(parent)
                        }
                    }
                }

                selectedNode = nextSelection
                selectedNodes = nextSelection.map { [$0] } ?? []
                try? await calculateStatistics(for: rootNode)
                if let root = rootNode {
                    rootNode = root
                }
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        }
    }

    func cancelMoveToTrash() {
        pendingTrashNodes = []
    }

    func nextSelection(afterDeleting nodes: Set<FileNode>) -> FileNode? {
        guard let anchor = nodes.first, let parent = anchor.parent,
              let index = parent.children.firstIndex(where: { $0 === anchor }) else {
            return nil
        }

        if let next = parent.children[index...].first(where: { !nodes.contains($0) }) {
            return next
        }
        return parent.children[..<index].last(where: { !nodes.contains($0) })
    }

    func moveToTrash(_ node: FileNode) {
        requestMoveToTrash([node])
    }

    func isProtectedFromTrash(_ url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }

        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedURL.path
        let parentPath = resolvedURL.deletingLastPathComponent().path
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().path

        if path == homePath || parentPath == "/" || parentPath == "/Users" || parentPath == "/Volumes" {
            return true
        }

        let protectedTrees = [
            "/System", "/Library", "/bin", "/sbin", "/usr", "/private",
            "/etc", "/tmp", "/var",
            homePath + "/Library"
        ]
        if protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }

        let protectedHomeFolders = [
            "Applications", "Desktop", "Documents", "Downloads", "Movies",
            "Music", "Pictures", "Public"
        ].map { homePath + "/" + $0 }
        return protectedHomeFolders.contains(path)
    }

    func color(for kindName: String) -> Color {
        colorAssigner.color(for: kindName)
    }

    func unscannedSize(total: UInt64, free: UInt64, scanned: UInt64) -> UInt64 {
        let used = total > free ? total - free : 0
        return used > scanned ? used - scanned : 0
    }

    // MARK: - Private Methods

    private func calculateStatistics(for root: FileNode?) async throws {
        guard let root else {
            kindStatistics = []
            return
        }

        let statisticsTask = Task.detached(priority: .utility) {
            var result: [String: (count: Int, size: UInt64)] = [:]
            var visitedNodes = 0

            func collect(_ node: FileNode) throws {
                visitedNodes += 1
                if visitedNodes.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                }
                if !node.isDirectory && !node.isSpecialItem {
                    let type = UTType(filenameExtension: node.url.pathExtension) ?? .data
                    let kind = type.localizedDescription ?? type.identifier
                    var stat = result[kind] ?? (count: 0, size: 0)
                    stat.count += 1
                    stat.size += node.size
                    result[kind] = stat
                }

                for child in node.children {
                    try collect(child)
                }
            }

            try collect(root)
            return result
        }
        let stats = try await withTaskCancellationHandler {
            try await statisticsTask.value
        } onCancel: {
            statisticsTask.cancel()
        }

        kindStatistics = stats.map { kind, stat in
            FileKindStatistic(
                kindName: kind,
                count: stat.count,
                totalSize: stat.size,
                color: colorAssigner.color(for: kind)
            )
        }.sorted { $0.totalSize > $1.totalSize }
    }

    private func protectedFoldersWithin(_ scanURL: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanPath = scanURL.standardizedFileURL.path
        return ["Desktop", "Documents", "Downloads"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { folder in
                let folderPath = folder.standardizedFileURL.path
                return folderPath == scanPath || folderPath.hasPrefix(scanPath == "/" ? "/" : scanPath + "/")
            }
    }

    private func addVolumeSpaceItems(for url: URL) async {
        guard let root = rootNode else { return }

        do {
            // Only add volume space items when scanning a volume root
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .isVolumeKey
            ])

            // Check if this is actually a volume root (like / or /Volumes/SomeDisk)
            let isVolumeRoot = resourceValues.isVolume ?? false
            let parentPath = url.deletingLastPathComponent().path
            let isVolumeMountPoint = parentPath == "/Volumes" || url.path == "/"

            guard isVolumeRoot || isVolumeMountPoint else {
                return // Not a volume root, don't add space items
            }

            guard let totalCapacity = resourceValues.volumeTotalCapacity,
                  let availableCapacity = resourceValues.volumeAvailableCapacity else {
                return
            }

            let scannedSize = root.size
            let totalSize = UInt64(totalCapacity)
            let freeSize = UInt64(availableCapacity)
            let otherSize = unscannedSize(total: totalSize, free: freeSize, scanned: scannedSize)

            if showOtherSpace && otherSize > 0 {
                let otherItem = FileNode(
                    url: url.appendingPathComponent("<Other Space>"),
                    name: "Other Space",
                    isDirectory: false,
                    isPackage: false,
                    size: otherSize,
                    type: .otherSpace
                )
                root.children.append(otherItem)
            }

            if showFreeSpace && freeSize > 0 {
                let freeItem = FileNode(
                    url: url.appendingPathComponent("<Free Space>"),
                    name: "Free Space",
                    isDirectory: false,
                    isPackage: false,
                    size: freeSize,
                    type: .freeSpace
                )
                root.children.append(freeItem)
            }

            root.size = root.children.reduce(0) { $0 + $1.size }
            root.children.sort { $0.size > $1.size }

        } catch {
            // Ignore volume info errors
        }
    }
}

// MARK: - Supporting Types

struct ScanProgress {
    let currentFolder: String
    let filesScanned: Int
    let foldersScanned: Int
}
