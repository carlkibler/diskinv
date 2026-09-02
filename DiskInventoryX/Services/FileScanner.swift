//
//  FileScanner.swift
//  DiskInventoryX
//
//  Async file system scanner
//

import Foundation
import OSLog
import UniformTypeIdentifiers

actor FileScanner {
    private static let logger = Logger(
        subsystem: "com.carlkibler.DiskInventoryXRay",
        category: "scanner"
    )
    private static let maximumVisibleChildren = 500
    private static let compactDirectoryThreshold: UInt64 = 8 * 1_024 * 1_024
    private static let summaryBatchInterval: TimeInterval = 1

    /// Folders whose contents nobody inspects. They are sized as one block and never expanded.
    private static let opaqueDirectoryNames: Set<String> = [
        ".build", ".cargo", ".git", ".gradle", ".hg", ".m2", ".next", ".nox", ".npm", ".nuxt",
        ".parcel-cache", ".pnpm-store", ".rustup", ".svn", ".svelte-kit", ".terraform",
        ".terragrunt-cache", ".tox", ".turbo", ".venv", ".yarn", "__pycache__",
        "bower_components", "Carthage", "node_modules", "Pods", "venv"
    ]

    /// Folders worth exactly one level of detail: each child is sized as a block, so the
    /// user sees which app or project owns the space without the scanner walking every file.
    private static let shallowDirectoryNames: Set<String> = [".cache", "DerivedData"]

    private static func opaqueDirectoryPaths(home: String) -> [String] {
        ["/System", "/private/var/folders", home + "/Library/pnpm/store"]
    }

    private static func shallowDirectoryPaths(home: String) -> [String] {
        [
            "/Library/Caches",
            home + "/Library/Caches",
            home + "/Library/Developer/CoreSimulator/Devices",
            home + "/Library/Developer/Xcode/iOS DeviceSupport"
        ]
    }

    private static let maxConcurrentOperations = max(
        1,
        min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    )
    private var cancellationState: CancellationState?

    // MARK: - Public API

    func cancel() {
        cancellationState?.cancel()
    }

    /// Scans `url` and returns the fully sized tree.
    ///
    /// The detailed walk finishes first and `treeReady` delivers that tree along with the number
    /// of folders still waiting for a size. Those folders are then sized in the background; every
    /// batch is applied to the tree on the main actor before `sizesResolved` reports how many remain.
    func scan(
        url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        mainDiskOnly: Bool = false,
        limits: ScanLimits = .standard,
        progress: @escaping (String, Int, Int) -> Void,
        treeReady: ((FileNode, Int) -> Void)? = nil,
        sizesResolved: ((Int) -> Void)? = nil
    ) async throws -> FileNode {
        let cancellation = CancellationState()
        cancellationState = cancellation
        defer { cancellationState = nil }

        let resourceKeys = Self.resourceKeys(usePhysicalSize: usePhysicalSize)
        let context = ScanContext(
            showPackageContents: showPackageContents,
            usePhysicalSize: usePhysicalSize,
            mainDiskOnly: mainDiskOnly,
            limits: limits,
            resourceKeys: resourceKeys,
            resourceKeyArray: Array(resourceKeys),
            cancellation: cancellation,
            progress: ProgressState(callback: progress),
            ioLimiter: IOLimiter(maxConcurrentOperations: Self.maxConcurrentOperations),
            pendingSummaries: PendingSummaries()
        )
        let scanTask = Task.detached(priority: .utility) {
            let root = try await Self.scanNode(
                url: url,
                context: context,
                detailBudget: DetailBudget(limits: limits),
                parallelizeChildren: true,
                depth: 0
            )
            guard let root else { throw CocoaError(.fileReadNoSuchFile) }
            root.sortChildrenBySize()

            let jobs = context.pendingSummaries.drain()
            treeReady?(root, jobs.count)
            try await Self.resolveSummaries(jobs, context: context, sizesResolved: sizesResolved)
            return root
        }
        let root = try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            cancellation.cancel()
            scanTask.cancel()
        }

        try cancellation.throwIfCancelled()
        try Task.checkCancellation()
        return root
    }

    // MARK: - Detailed walk

    private nonisolated static func scanNode(
        url: URL,
        context: ScanContext,
        detailBudget: DetailBudget,
        parallelizeChildren: Bool,
        depth: Int
    ) async throws -> FileNode? {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()

        if context.mainDiskOnly && depth > 0 && isExcludedMainDiskPath(url) {
            return nil
        }

        guard detailBudget.claimNode() else {
            throw DetailBudgetExceeded()
        }

        let values = try await withIOPermit(context.ioLimiter) {
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            return try autoreleasepool {
                try url.resourceValues(forKeys: context.resourceKeys)
            }
        }

        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()

        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let isAlias = values.isAliasFile ?? false

        if context.mainDiskOnly && depth > 0
            && shouldSkipDuringMainDiskScan(url: url, volumeURL: values.volume) {
            return nil
        }

        let size: UInt64
        if context.usePhysicalSize {
            size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        } else {
            size = UInt64(values.fileSize ?? 0)
        }

        let node = FileNode(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? 0 : size
        )

        if isDirectory {
            context.progress.recordDirectory(url.lastPathComponent, displayName: depth <= 2)
        } else {
            context.progress.recordFile()
        }

        // Don't follow symlinks or aliases to avoid infinite loops.
        if isSymlink || isAlias {
            return node
        }

        let opaque = isDirectory && (
            Self.isSummarizedWithoutDetail(url) || (!context.showPackageContents && isPackage)
        )
        let directoryEntryCount: Int
        if isDirectory && !opaque {
            directoryEntryCount = (try? await withIOPermit(context.ioLimiter) {
                try url.resourceValues(forKeys: [.directoryEntryCountKey]).directoryEntryCount ?? 0
            }) ?? 0
        } else {
            directoryEntryCount = 0
        }
        let shouldSummarize = (depth > 0 || isPackage) && (
            opaque || directoryEntryCount > context.limits.maximumDirectoryEntries
        )
        if shouldSummarize {
            deferSizing(of: node, context: context)
            return node
        }

        // Scan children if this is a directory (and not a package, unless configured to show package contents).
        guard isDirectory && (context.showPackageContents || !isPackage) else {
            return node
        }

        let contents: [URL]
        do {
            contents = try await withIOPermit(context.ioLimiter) {
                try context.cancellation.throwIfCancelled()
                try Task.checkCancellation()
                return try autoreleasepool {
                    try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: context.mainDiskOnly ? [] : context.resourceKeyArray,
                        options: []
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the fact that this directory could not be measured.
            node.children = [incompleteMarker("Contents could not be read")]
            node.children[0].parent = node
            return node
        }

        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()

        let orderedContents = prioritizedUserData(in: contents)
        var children = ChildAccumulator(limit: Self.maximumVisibleChildren)
        if parallelizeChildren {
            // Only the root's immediate children run as tasks. Nested branches recurse
            // serially, so a million-file directory cannot create a million suspended tasks.
            try await withThrowingTaskGroup(of: FileNode?.self) { group in
                var nextChildIndex = 0
                func addNextChildTask() {
                    guard nextChildIndex < orderedContents.count else { return }
                    let childURL = orderedContents[nextChildIndex]
                    let childDetailBudget = DetailBudget(limits: context.limits)
                    nextChildIndex += 1
                    group.addTask {
                        do {
                            return try await scanNode(
                                url: childURL,
                                context: context,
                                detailBudget: childDetailBudget,
                                parallelizeChildren: false,
                                depth: depth + 1
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch is DetailBudgetExceeded {
                            do {
                                return try await summarizedNode(
                                    at: childURL,
                                    context: context,
                                    depth: depth + 1
                                )
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                return incompleteNode(for: childURL)
                            }
                        } catch {
                            return incompleteNode(for: childURL)
                        }
                    }
                }

                for _ in 0..<min(Self.maxConcurrentOperations, orderedContents.count) {
                    addNextChildTask()
                }

                while let child = try await group.next() {
                    if let child {
                        child.parent = node
                        children.add(child)
                        node.size += child.size
                    }
                    addNextChildTask()
                }
            }
        } else {
            for childURL in orderedContents {
                try context.cancellation.throwIfCancelled()
                try Task.checkCancellation()
                do {
                    let child = try await scanNode(
                        url: childURL,
                        context: context,
                        detailBudget: detailBudget,
                        parallelizeChildren: false,
                        depth: depth + 1
                    )
                    guard let child else { continue }
                    child.parent = node
                    children.add(child)
                    node.size += child.size
                } catch is CancellationError {
                    throw CancellationError()
                } catch is DetailBudgetExceeded {
                    throw DetailBudgetExceeded()
                } catch {
                    let child = incompleteNode(for: childURL)
                    child.parent = node
                    children.add(child)
                }
            }

        }

        node.children = children.finished()
        if depth > 1
            && node.size < Self.compactDirectoryThreshold
            && !node.children.isEmpty
            && !node.containsNode(where: { $0.type == .incompleteSummary || $0.isSizePending }) {
            // Small folders keep their total but drop their subtree, which bounds memory.
            node.children = []
            node.isSummarized = true
        }
        node.children.forEach { $0.parent = node }
        return node
    }

    /// Marks `node` as a block to be sized after the tree is shown.
    private nonisolated static func deferSizing(of node: FileNode, context: ScanContext) {
        node.isSummarized = true
        node.isSizePending = true
        context.pendingSummaries.enqueue(SummaryJob(node: node, url: node.url))
    }

    private nonisolated static func summaryURL() -> URL {
        URL(string: "disk-inventory-x-ray://summary/\(UUID().uuidString)")!
    }

    private nonisolated static func incompleteMarker(_ name: String) -> FileNode {
        FileNode(url: summaryURL(), name: name, size: 0, type: .incompleteSummary)
    }

    private nonisolated static func incompleteNode(for url: URL) -> FileNode {
        FileNode(url: url, name: "Could not be read", size: 0, type: .incompleteSummary)
    }

    /// Fallback for a top-level branch whose detailed walk exceeded its budget.
    private nonisolated static func summarizedNode(
        at url: URL,
        context: ScanContext,
        depth: Int
    ) async throws -> FileNode? {
        let values = try await withIOPermit(context.ioLimiter) {
            try context.cancellation.throwIfCancelled()
            return try url.resourceValues(forKeys: context.resourceKeys)
        }
        guard values.isDirectory == true else {
            let size = context.usePhysicalSize
                ? UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                : UInt64(values.fileSize ?? 0)
            context.progress.recordFile()
            return FileNode(url: url, name: values.name, size: size)
        }
        if context.mainDiskOnly && depth > 0
            && shouldSkipDuringMainDiskScan(url: url, volumeURL: values.volume) {
            return nil
        }

        context.progress.recordDirectory(url.lastPathComponent, displayName: depth <= 2)
        let node = FileNode(
            url: url,
            name: values.name,
            isDirectory: true,
            isPackage: values.isPackage ?? false,
            size: 0
        )
        deferSizing(of: node, context: context)
        return node
    }

    // MARK: - Background sizing

    private nonisolated static func resolveSummaries(
        _ jobs: [SummaryJob],
        context: ScanContext,
        sizesResolved: ((Int) -> Void)?
    ) async throws {
        guard !jobs.isEmpty else { return }

        try await withThrowingTaskGroup(of: SummaryResolution.self) { group in
            var nextJobIndex = 0
            func addNextJob() {
                guard nextJobIndex < jobs.count else { return }
                let job = jobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    SummaryResolution(job: job, result: try await aggregateSize(of: job.url, context: context))
                }
            }

            for _ in 0..<min(Self.maxConcurrentOperations, jobs.count) {
                addNextJob()
            }

            var remaining = jobs.count
            var batch: [SummaryResolution] = []
            var lastFlush = ProcessInfo.processInfo.systemUptime
            while let resolution = try await group.next() {
                batch.append(resolution)
                remaining -= 1
                addNextJob()

                let now = ProcessInfo.processInfo.systemUptime
                guard remaining == 0 || now - lastFlush >= Self.summaryBatchInterval else { continue }
                let toApply = batch
                batch = []
                lastFlush = now
                await MainActor.run { Self.apply(toApply) }
                sizesResolved?(remaining)
            }
        }
    }

    /// Writes resolved sizes into the tree. Runs on the main actor so the UI never reads a
    /// half-updated node.
    @MainActor
    private static func apply(_ resolutions: [SummaryResolution]) {
        var parentsToSort = Set<FileNode>()
        for resolution in resolutions {
            let node = resolution.job.node
            let size = resolution.result?.size ?? 0
            node.isSizePending = false
            node.size = size
            if resolution.result?.isComplete != true {
                let marker = incompleteMarker(
                    resolution.result == nil ? "Contents could not be sized" : "Some contents could not be read"
                )
                marker.parent = node
                node.children = [marker]
            }

            var ancestor = node.parent
            while let current = ancestor {
                current.size += size
                parentsToSort.insert(current)
                ancestor = current.parent
            }
        }
        for parent in parentsToSort {
            parent.children.sort { $0.size > $1.size }
        }
    }

    private nonisolated static func aggregateSize(
        of url: URL,
        context: ScanContext
    ) async throws -> AggregateResult? {
        try context.cancellation.throwIfCancelled()

        let allowedDuration = context.limits.maximumSummaryDuration
        guard allowedDuration > 0 else { return nil }

        let process = Process()
        let output = Pipe()
        let exitState = ProcessExitState()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        var arguments = context.usePhysicalSize ? ["-skx"] : ["-Askx"]
        for name in summaryExcludedNames(for: url, mainDiskOnly: context.mainDiskOnly) {
            arguments.append(contentsOf: ["-I", name])
        }
        arguments.append(url.path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exitState.signalExit() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard context.cancellation.register(process) else {
            await terminate(process, exitState: exitState)
            throw CancellationError()
        }
        defer { context.cancellation.unregister(process) }

        // Read concurrently so a large tree cannot fill the pipe and stall du.
        let reader = Task.detached(priority: .utility) {
            output.fileHandleForReading.readDataToEndOfFile()
        }

        if !(await exitState.wait(timeout: allowedDuration)) {
            Self.logger.notice(
                "Aggregate sizing reached its \(allowedDuration, privacy: .public)-second limit for \(url.path, privacy: .private(mask: .hash))"
            )
            await terminate(process, exitState: exitState)
            reader.cancel()
            try context.cancellation.throwIfCancelled()
            return nil
        }

        try context.cancellation.throwIfCancelled()
        let data = await reader.value
        return parseAggregateResult(output: data, terminationStatus: process.terminationStatus)
    }

    nonisolated static func parseAggregateResult(
        output: Data,
        terminationStatus: Int32
    ) -> AggregateResult? {
        guard let text = String(data: output, encoding: .utf8),
              let firstField = text.split(whereSeparator: \Character.isWhitespace).first,
              let blocks = UInt64(firstField) else {
            return nil
        }
        let bytes = blocks.multipliedReportingOverflow(by: 1_024)
        return AggregateResult(
            size: bytes.overflow ? UInt64.max : bytes.partialValue,
            isComplete: terminationStatus == 0
        )
    }

    private nonisolated static func terminate(
        _ process: Process,
        exitState: ProcessExitState
    ) async {
        process.terminate()
        guard !(await exitState.wait(timeout: 1)), process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await exitState.wait(timeout: 1)
    }

    // MARK: - Policy

    /// True for folders that are sized as a single block: version-control and dependency
    /// caches, sealed system trees, and the immediate children of shallow folders such as
    /// `~/Library/Caches`, where the interesting question is which app owns the space.
    nonisolated static func isSummarizedWithoutDetail(_ url: URL) -> Bool {
        if opaqueDirectoryNames.contains(url.lastPathComponent) {
            return true
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if opaqueDirectoryPaths(home: home).contains(path) || path.hasSuffix("/vendor/bundle") {
            return true
        }

        let parent = url.deletingLastPathComponent()
        return shallowDirectoryNames.contains(parent.lastPathComponent)
            || shallowDirectoryPaths(home: home).contains(parent.standardizedFileURL.path)
    }

    nonisolated static func summaryExcludedNames(for url: URL, mainDiskOnly: Bool) -> [String] {
        guard mainDiskOnly else { return [] }

        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/System" {
            return ["Volumes"]
        }
        if path == "/Users" || path == home || path == home + "/Library" {
            return ["CloudStorage", "Mobile Documents"]
        }
        return []
    }

    private nonisolated static func resourceKeys(usePhysicalSize: Bool) -> Set<URLResourceKey> {
        var keys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .volumeURLKey
        ]
        if usePhysicalSize {
            keys.insert(.totalFileAllocatedSizeKey)
        }
        return keys
    }

    nonisolated static func shouldSkipDuringMainDiskScan(url: URL, volumeURL: URL?) -> Bool {
        if isExcludedMainDiskPath(url) {
            return true
        }

        guard let volumeURL else { return true }
        return volumeURL.standardizedFileURL.path != "/"
    }

    nonisolated static func prioritizedUserData(in contents: [URL]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return contents.filter {
            let path = $0.standardizedFileURL.path
            return path == "/Users" || path == home
        } + contents.filter {
            let path = $0.standardizedFileURL.path
            return path != "/Users" && path != home
        }
    }

    private nonisolated static func isExcludedMainDiskPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let rootLookupNamespaces = ["/.file", "/.nofollow", "/.resolve", "/.vol"]
        let excludedTrees = [
            "/Network",
            "/Volumes",
            "/System/Volumes",
            home + "/Library/CloudStorage",
            home + "/Library/Mobile Documents"
        ]

        return rootLookupNamespaces.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            || excludedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    private nonisolated static func withIOPermit<T>(
        _ ioLimiter: IOLimiter,
        operation: () async throws -> T
    ) async throws -> T {
        await ioLimiter.acquire()
        do {
            let result = try await operation()
            await ioLimiter.release()
            return result
        } catch {
            await ioLimiter.release()
            throw error
        }
    }
}

struct AggregateResult: Equatable, Sendable {
    let size: UInt64
    let isComplete: Bool
}

/// Everything a scan shares across its tasks. One instance per `scan` call.
private struct ScanContext: @unchecked Sendable {
    let showPackageContents: Bool
    let usePhysicalSize: Bool
    let mainDiskOnly: Bool
    let limits: ScanLimits
    let resourceKeys: Set<URLResourceKey>
    let resourceKeyArray: [URLResourceKey]
    let cancellation: CancellationState
    let progress: ProgressState
    let ioLimiter: IOLimiter
    let pendingSummaries: PendingSummaries
}

private struct SummaryJob: @unchecked Sendable {
    let node: FileNode
    let url: URL
}

private struct SummaryResolution: @unchecked Sendable {
    let job: SummaryJob
    let result: AggregateResult?
}

private final class PendingSummaries: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [SummaryJob] = []

    func enqueue(_ job: SummaryJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    func drain() -> [SummaryJob] {
        lock.lock()
        defer { lock.unlock() }
        let drained = jobs
        jobs = []
        return drained
    }
}

private struct ChildAccumulator {
    private let limit: Int
    private var retained: [FileNode] = []
    private var summarizedSize: UInt64 = 0
    private var summarizedCount = 0
    private var summarizedIncomplete = false

    init(limit: Int) {
        self.limit = limit
    }

    mutating func add(_ child: FileNode) {
        retained.append(child)
        if retained.count >= limit * 2 {
            compact()
        }
    }

    mutating func finished() -> [FileNode] {
        compact()
        guard summarizedCount > 0 else { return retained }
        retained.append(FileNode(
            url: URL(string: "disk-inventory-x-ray://summary/\(UUID().uuidString)")!,
            name: summarizedIncomplete
                ? "Contents not fully scanned"
                : "Summarized Items (\(summarizedCount.formatted()))",
            size: summarizedSize,
            type: summarizedIncomplete ? .incompleteSummary : .summary
        ))
        return retained
    }

    private mutating func compact() {
        guard retained.count > limit else { return }
        retained.sort { $0.size > $1.size }
        // A child still waiting for its size cannot be folded into the total yet, so keep it.
        var kept: [FileNode] = Array(retained.prefix(limit))
        for child in retained.dropFirst(limit) {
            if child.containsNode(where: { $0.isSizePending }) {
                kept.append(child)
                continue
            }
            summarizedSize += child.size
            summarizedCount += 1
            summarizedIncomplete = summarizedIncomplete
                || child.containsNode(where: { $0.type == .incompleteSummary })
        }
        retained = kept
    }
}

private final class ProcessExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    func signalExit() {
        lock.lock()
        exited = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(returning: true) }
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }

            let waiterID = nextWaiterID
            nextWaiterID += 1
            waiters[waiterID] = continuation
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                self.timeout(waiterID)
            }
        }
    }

    private func timeout(_ waiterID: Int) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(returning: false)
    }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [ObjectIdentifier: Process] = [:]

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcesses = Array(processes.values)
        lock.unlock()
        runningProcesses.forEach { $0.terminate() }
    }

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        processes[ObjectIdentifier(process)] = process
        return true
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func throwIfCancelled() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

struct ScanLimits: Sendable {
    static let standard = ScanLimits(
        maximumDetailedNodes: 1_000_000,
        maximumDetailedDuration: .infinity,
        maximumDirectoryEntries: 10_000
    )

    /// Nodes one top-level branch may walk in detail before it falls back to a block size.
    let maximumDetailedNodes: Int
    let maximumDetailedDuration: TimeInterval
    /// Directories with more entries than this are sized as a block instead of listed.
    let maximumDirectoryEntries: Int
    /// Safety net per block: a `du` that runs longer than this is abandoned and the folder
    /// is marked as unsized. Blocks run in the background, so this can be generous.
    let maximumSummaryDuration: TimeInterval

    init(
        maximumDetailedNodes: Int,
        maximumDetailedDuration: TimeInterval,
        maximumDirectoryEntries: Int,
        maximumSummaryDuration: TimeInterval = 600
    ) {
        self.maximumDetailedNodes = maximumDetailedNodes
        self.maximumDetailedDuration = maximumDetailedDuration
        self.maximumDirectoryEntries = maximumDirectoryEntries
        self.maximumSummaryDuration = maximumSummaryDuration
    }
}

private struct DetailBudgetExceeded: Error {}

private final class DetailBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: ScanLimits
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var claimedNodes = 0

    init(limits: ScanLimits) {
        self.limits = limits
    }

    func claimNode() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        claimedNodes += 1
        return claimedNodes <= limits.maximumDetailedNodes
            && ProcessInfo.processInfo.systemUptime - startedAt <= limits.maximumDetailedDuration
    }
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackLock = NSLock()
    private let callback: (String, Int, Int) -> Void
    private var fileCount = 0
    private var folderCount = 0
    private var currentDirectory = ""
    private var lastReportTime = -Double.infinity

    init(callback: @escaping (String, Int, Int) -> Void) {
        self.callback = callback
    }

    func recordFile() {
        lock.lock()
        fileCount += 1
        let report = nextReportIfNeeded()
        if report != nil {
            callbackLock.lock()
        }
        lock.unlock()
        send(report)
    }

    func recordDirectory(_ name: String, displayName: Bool) {
        lock.lock()
        folderCount += 1
        if displayName {
            currentDirectory = name
        }
        let report = nextReportIfNeeded()
        if report != nil {
            callbackLock.lock()
        }
        lock.unlock()
        send(report)
    }

    private func nextReportIfNeeded() -> (String, Int, Int)? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReportTime >= 0.1 else { return nil }
        lastReportTime = now
        return (currentDirectory, fileCount, folderCount)
    }

    private func send(_ report: (String, Int, Int)?) {
        guard let report else { return }
        callback(report.0, report.1, report.2)
        callbackLock.unlock()
    }
}

private actor IOLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentOperations: Int) {
        availablePermits = max(1, maxConcurrentOperations)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            availablePermits += 1
        }
    }
}
