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
    /// Folders still being sized in the background after the tree appeared.
    @Published var pendingSummaryCount = 0
    /// Bumped whenever the tree changes in place (sizes resolved, items trashed) so views
    /// that cache layout or rows know to rebuild.
    @Published var treeGeneration = 0
    @Published var errorMessage: String?
    @Published var trashProtectionMessage: String?
    @Published var pendingTrashNodes: [FileNode] = []

    @Published var kindStatistics: [FileKindStatistic] = []
    @Published var selectedKind: String?

    // MARK: - Settings

    @AppStorage("showPhysicalSize") var showPhysicalSize = true
    @AppStorage("showPackageContents") var showPackageContents = false
    @AppStorage("ignoreCreatorCodes") var ignoreCreatorCodes = true
    @AppStorage("showFreeSpace") var showFreeSpace = true
    @AppStorage("showOtherSpace") var showOtherSpace = true

    // MARK: - Private

    private var scanner: FileScanner?
    private var activeScanToken = UUID()
    private var scannedVolumeURL: URL?
    private var colorAssigner = FileKindColorAssigner()

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

        let token = UUID()
        activeScanToken = token
        isScanning = true
        scanProgress = ScanProgress(currentFolder: url.lastPathComponent, filesScanned: 0, foldersScanned: 0)
        errorMessage = nil
        rootNode = nil
        zoomedNode = nil
        zoomStack = []
        selectedNode = nil
        selectedNodes = []
        kindStatistics = []
        pendingSummaryCount = 0
        scannedVolumeURL = nil

        let newScanner = FileScanner()
        scanner = newScanner

        do {
            _ = try await newScanner.scan(
                url: url,
                showPackageContents: showPackageContents,
                usePhysicalSize: showPhysicalSize,
                mainDiskOnly: url.standardizedFileURL.path == "/",
                progress: { [weak self] folder, files, folders in
                    Task { @MainActor in
                        guard let self, self.activeScanToken == token else { return }
                        self.scanProgress = ScanProgress(
                            currentFolder: folder,
                            filesScanned: files,
                            foldersScanned: folders
                        )
                    }
                },
                treeReady: { [weak self] root, pending in
                    Task { @MainActor in
                        guard let self, self.activeScanToken == token else { return }
                        self.presentTree(root, scannedURL: url, pendingSummaries: pending)
                    }
                },
                sizesResolved: { [weak self] remaining in
                    Task { @MainActor in
                        guard let self, self.activeScanToken == token else { return }
                        self.treeSizesChanged(remaining: remaining)
                    }
                }
            )
        } catch is CancellationError {
            // Scan was cancelled, ignore
        } catch {
            guard activeScanToken == token else { return }
            errorMessage = error.localizedDescription
        }

        guard activeScanToken == token else { return }
        isScanning = false
        scanProgress = nil
        pendingSummaryCount = 0
    }

    /// Shows the detailed tree while summarized folders are still being sized.
    private func presentTree(_ root: FileNode, scannedURL: URL, pendingSummaries: Int) {
        rootNode = root
        isScanning = false
        scanProgress = nil
        pendingSummaryCount = pendingSummaries
        scannedVolumeURL = scannedURL
        calculateStatistics(for: root)
        updateVolumeSpaceItems()
    }

    private func treeSizesChanged(remaining: Int) {
        pendingSummaryCount = remaining
        updateVolumeSpaceItems()
        treeGeneration += 1
    }

    func scanPreset(url: URL) async {
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
        if let protectedNode = nodes.first(where: {
            isProtectedFromTrash($0.url, isDirectory: $0.isDirectory)
        }) {
            trashProtectionMessage = "\(protectedNode.name) is a top-level or system folder. Removing it here is too dangerous, so Disk Inventory X-Ray will not enable that action."
            return
        }

        // The Trash is reversible, so a single ordinary item goes straight there. Ask only
        // for a batch, or for folders whose loss is hard to notice until something breaks.
        if nodes.count == 1, !needsTrashConfirmation(nodes[0].url, isDirectory: nodes[0].isDirectory) {
            performMoveToTrash(nodes)
            return
        }
        pendingTrashNodes = nodes.sorted { $0.displayPath < $1.displayPath }
    }

    func confirmMoveToTrash() {
        let nodes = pendingTrashNodes
        pendingTrashNodes = []
        performMoveToTrash(nodes)
    }

    private func performMoveToTrash(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let nextSelection = nextSelection(afterDeleting: Set(nodes))
        let urls = nodes.map(\.url)
        let token = activeScanToken

        Task {
            do {
                try await Task.detached(priority: .utility) {
                    for url in urls {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }.value
                // A rescan replaced the tree these nodes belonged to; nothing left to update.
                guard activeScanToken == token else { return }

                var ancestors = Set(nodes.compactMap(\.parent))
                for node in nodes {
                    node.parent?.children.removeAll { $0 === node }
                    // Detach so a background size landing later cannot flow into the live tree.
                    node.parent = nil
                }

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
                calculateStatistics(for: rootNode)
                updateVolumeSpaceItems()
                treeGeneration += 1
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
            "/etc", "/tmp", "/var"
        ]
        if protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }

        // ~/Library and its immediate children (Caches, Application Support, ...) stay
        // put; folders inside them are fair game for cleanup, with confirmation.
        let libraryPath = homePath + "/Library"
        if path == libraryPath || parentPath == libraryPath {
            return true
        }

        let protectedHomeFolders = [
            "Applications", "Desktop", "Documents", "Downloads", "Movies",
            "Music", "Pictures", "Public"
        ].map { homePath + "/" + $0 }
        return protectedHomeFolders.contains(path)
    }

    /// Folders that are easy to trash by accident and painful to discover missing:
    /// anything inside ~/Library, hidden config folders in the home directory, and
    /// other folders sitting directly in the home directory.
    func needsTrashConfirmation(_ url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }

        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedURL.path
        let parentPath = resolvedURL.deletingLastPathComponent().path
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().path

        if path.hasPrefix(homePath + "/Library/") {
            return true
        }
        if parentPath == homePath {
            return true
        }
        let hiddenHomeFolders = resolvedURL.pathComponents.dropFirst(
            URL(fileURLWithPath: homePath).pathComponents.count
        )
        return hiddenHomeFolders.first?.hasPrefix(".") == true
    }

    func color(for kindName: String) -> Color {
        colorAssigner.color(for: kindName)
    }

    func unscannedSize(total: UInt64, free: UInt64, scanned: UInt64) -> UInt64 {
        let used = total > free ? total - free : 0
        return used > scanned ? used - scanned : 0
    }

    // MARK: - Private Methods

    /// Walks the tree on the main actor. Background sizing also writes on the main actor,
    /// so this never observes a half-applied batch. One pass per scan is cheap enough.
    private func calculateStatistics(for root: FileNode?) {
        guard let root else {
            kindStatistics = []
            return
        }

        var result: [String: (count: Int, size: UInt64)] = [:]
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if !node.isDirectory && !node.isSpecialItem {
                let type = UTType(filenameExtension: node.url.pathExtension) ?? .data
                let kind = type.localizedDescription ?? type.identifier
                var stat = result[kind] ?? (count: 0, size: 0)
                stat.count += 1
                stat.size += node.size
                result[kind] = stat
            }
            stack.append(contentsOf: node.children)
        }

        kindStatistics = result.map { kind, stat in
            FileKindStatistic(
                kindName: kind,
                count: stat.count,
                totalSize: stat.size,
                color: colorAssigner.color(for: kind)
            )
        }.sorted { $0.totalSize > $1.totalSize }
    }

    /// Rebuilds the Free Space and Other Space rows from the current scanned total. Safe to
    /// call repeatedly as background sizes land.
    private func updateVolumeSpaceItems() {
        guard let root = rootNode, let url = scannedVolumeURL else { return }

        root.children.removeAll { [.otherSpace, .unscannedSpace, .freeSpace].contains($0.type) }
        root.size = root.children.reduce(0) { $0 + $1.size }
        defer { root.children.sort { $0.size > $1.size } }

        guard showFreeSpace || showOtherSpace else { return }

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
                let scanIsIncomplete = root.containsNode { $0.type == .incompleteSummary }
                let otherItem = FileNode(
                    url: url.appendingPathComponent(scanIsIncomplete ? "<Not Scanned>" : "<Other Space>"),
                    name: scanIsIncomplete ? "Not Scanned" : "Other Space",
                    isDirectory: false,
                    isPackage: false,
                    size: otherSize,
                    type: scanIsIncomplete ? .unscannedSpace : .otherSpace
                )
                otherItem.parent = root
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
                freeItem.parent = root
                root.children.append(freeItem)
            }

            root.size = root.children.reduce(0) { $0 + $1.size }

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
