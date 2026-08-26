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
    private static let highCardinalityDirectoryNames: Set<String> = [
        ".build", ".cache", ".cargo", ".git", ".gradle", ".hg", ".m2", ".next",
        ".nox", ".npm", ".nuxt", ".parcel-cache", ".pnpm-store", ".rustup", ".svn",
        ".svelte-kit", ".terraform", ".terragrunt-cache", ".tox", ".turbo", ".venv",
        ".yarn", "__pycache__", "bower_components", "Carthage", "DerivedData", "node_modules",
        "Pods", "venv"
    ]
    private static let maxConcurrentOperations = max(
        1,
        min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    )
    private var cancellationState: CancellationState?

    // MARK: - Public API

    func cancel() {
        cancellationState?.cancel()
    }

    func scan(
        url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        mainDiskOnly: Bool = false,
        limits: ScanLimits = .standard,
        progress: @escaping (String, Int, Int) -> Void
    ) async throws -> FileNode {
        let cancellation = CancellationState()
        cancellationState = cancellation
        defer { cancellationState = nil }

        let progressState = ProgressState(callback: progress)
        let ioLimiter = IOLimiter(maxConcurrentOperations: Self.maxConcurrentOperations)
        let summaryLimiter = IOLimiter(maxConcurrentOperations: 2)
        let detailBudget = DetailBudget(limits: limits)
        let resourceKeys = Self.resourceKeys(usePhysicalSize: usePhysicalSize)
        let resourceKeyArray = Array(resourceKeys)
        let scanTask = Task.detached(priority: .utility) {
            let root = try await Self.scanNode(
                url: url,
                showPackageContents: showPackageContents,
                usePhysicalSize: usePhysicalSize,
                resourceKeys: resourceKeys,
                resourceKeyArray: resourceKeyArray,
                cancellation: cancellation,
                progress: progressState,
                ioLimiter: ioLimiter,
                summaryLimiter: summaryLimiter,
                detailBudget: detailBudget,
                limits: limits,
                mainDiskOnly: mainDiskOnly,
                parallelizeChildren: true,
                depth: 0
            )
            guard let root else { throw CocoaError(.fileReadNoSuchFile) }
            root.sortChildrenBySize()
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

    // MARK: - Private Implementation

    private nonisolated static func scanNode(
        url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        resourceKeys: Set<URLResourceKey>,
        resourceKeyArray: [URLResourceKey],
        cancellation: CancellationState,
        progress: ProgressState,
        ioLimiter: IOLimiter,
        summaryLimiter: IOLimiter,
        detailBudget: DetailBudget,
        limits: ScanLimits,
        mainDiskOnly: Bool,
        parallelizeChildren: Bool,
        depth: Int
    ) async throws -> FileNode? {
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()

        if mainDiskOnly && depth > 0 && isExcludedMainDiskPath(url) {
            return nil
        }

        guard detailBudget.claimNode() else {
            throw DetailBudgetExceeded()
        }

        let values = try await withIOPermit(ioLimiter) {
            try cancellation.throwIfCancelled()
            try Task.checkCancellation()
            return try autoreleasepool {
                try url.resourceValues(forKeys: resourceKeys)
            }
        }

        try cancellation.throwIfCancelled()
        try Task.checkCancellation()

        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let isAlias = values.isAliasFile ?? false

        if mainDiskOnly && depth > 0 && shouldSkipDuringMainDiskScan(url: url, volumeURL: values.volume) {
            return nil
        }

        let size: UInt64
        if usePhysicalSize {
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
            progress.recordDirectory(url.lastPathComponent, displayName: depth <= 2)
        } else {
            progress.recordFile()
        }

        // Don't follow symlinks or aliases to avoid infinite loops.
        if isSymlink || isAlias {
            return node
        }

        let knownOpaqueDirectory = isDirectory && (
            Self.isKnownHighCardinalityDirectory(url) || (!showPackageContents && isPackage)
        )
        let directoryEntryCount: Int
        if isDirectory && !knownOpaqueDirectory {
            directoryEntryCount = (try? await withIOPermit(ioLimiter) {
                try url.resourceValues(forKeys: [.directoryEntryCountKey]).directoryEntryCount ?? 0
            }) ?? 0
        } else {
            directoryEntryCount = 0
        }
        let shouldSummarize = (depth > 0 || isPackage) && (
            knownOpaqueDirectory || directoryEntryCount > limits.maximumDirectoryEntries
        )
        if shouldSummarize {
            let aggregate: AggregateResult?
            do {
                aggregate = try await summarizedDirectorySize(
                    url: url,
                    usePhysicalSize: usePhysicalSize,
                    cancellation: cancellation,
                    summaryLimiter: summaryLimiter,
                    detailBudget: detailBudget,
                    limits: limits,
                    mainDiskOnly: mainDiskOnly
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                aggregate = nil
            }
            node.size = aggregate?.size ?? 0
            if !isPackage || aggregate?.isComplete != true {
                node.children = [summaryNode(size: node.size, complete: aggregate?.isComplete == true)]
                node.children[0].parent = node
            }
            return node
        }

        // Scan children if this is a directory (and not a package, unless configured to show package contents).
        guard isDirectory && (showPackageContents || !isPackage) else {
            return node
        }

        let contents: [URL]
        do {
            contents = try await withIOPermit(ioLimiter) {
                try cancellation.throwIfCancelled()
                try Task.checkCancellation()
                return try autoreleasepool {
                    try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: mainDiskOnly ? [] : resourceKeyArray,
                        options: []
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the fact that this directory could not be measured.
            node.children = [summaryNode(size: 0, complete: false)]
            node.children[0].parent = node
            return node
        }

        try cancellation.throwIfCancelled()
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
                    let childDetailBudget = DetailBudget(limits: limits)
                    nextChildIndex += 1
                    group.addTask {
                        do {
                            return try await scanNode(
                                url: childURL,
                                showPackageContents: showPackageContents,
                                usePhysicalSize: usePhysicalSize,
                                resourceKeys: resourceKeys,
                                resourceKeyArray: resourceKeyArray,
                                cancellation: cancellation,
                                progress: progress,
                                ioLimiter: ioLimiter,
                                summaryLimiter: summaryLimiter,
                                detailBudget: childDetailBudget,
                                limits: limits,
                                mainDiskOnly: mainDiskOnly,
                                parallelizeChildren: false,
                                depth: depth + 1
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch is DetailBudgetExceeded {
                            do {
                                return try await summarizedNode(
                                    at: childURL,
                                    showPackageContents: showPackageContents,
                                    usePhysicalSize: usePhysicalSize,
                                    resourceKeys: resourceKeys,
                                    cancellation: cancellation,
                                    progress: progress,
                                    ioLimiter: ioLimiter,
                                    summaryLimiter: summaryLimiter,
                                    detailBudget: childDetailBudget,
                                    limits: limits,
                                    mainDiskOnly: mainDiskOnly,
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
                try cancellation.throwIfCancelled()
                try Task.checkCancellation()
                do {
                    let child = try await scanNode(
                        url: childURL,
                        showPackageContents: showPackageContents,
                        usePhysicalSize: usePhysicalSize,
                        resourceKeys: resourceKeys,
                        resourceKeyArray: resourceKeyArray,
                        cancellation: cancellation,
                        progress: progress,
                        ioLimiter: ioLimiter,
                        summaryLimiter: summaryLimiter,
                        detailBudget: detailBudget,
                        limits: limits,
                        mainDiskOnly: mainDiskOnly,
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
            && !node.containsNode(where: { $0.type == .incompleteSummary }) {
            node.children = [FileNode(
                url: summaryURL(),
                name: "Summarized Items",
                size: node.size,
                type: .summary
            )]
        }
        node.children.forEach { $0.parent = node }
        return node
    }

    private nonisolated static func summaryURL() -> URL {
        URL(string: "disk-inventory-x-ray://summary/\(UUID().uuidString)")!
    }

    private nonisolated static func summaryNode(size: UInt64, complete: Bool = true) -> FileNode {
        FileNode(
            url: summaryURL(),
            name: complete
                ? "Contents summarized for faster scanning"
                : "Contents not sized before the scan limit",
            size: size,
            type: complete ? .summary : .incompleteSummary
        )
    }

    private nonisolated static func incompleteNode(for url: URL) -> FileNode {
        FileNode(
            url: url,
            name: "Contents not sized before the scan limit",
            size: 0,
            type: .incompleteSummary
        )
    }

    private nonisolated static func summarizedNode(
        at url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        resourceKeys: Set<URLResourceKey>,
        cancellation: CancellationState,
        progress: ProgressState,
        ioLimiter: IOLimiter,
        summaryLimiter: IOLimiter,
        detailBudget: DetailBudget,
        limits: ScanLimits,
        mainDiskOnly: Bool,
        depth: Int
    ) async throws -> FileNode? {
        let values = try await withIOPermit(ioLimiter) {
            try cancellation.throwIfCancelled()
            return try url.resourceValues(forKeys: resourceKeys)
        }
        guard values.isDirectory == true else {
            let size = usePhysicalSize
                ? UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                : UInt64(values.fileSize ?? 0)
            progress.recordFile()
            return FileNode(url: url, name: values.name, size: size)
        }
        if mainDiskOnly && depth > 0 && shouldSkipDuringMainDiskScan(url: url, volumeURL: values.volume) {
            return nil
        }

        progress.recordDirectory(url.lastPathComponent, displayName: depth <= 2)
        let aggregate: AggregateResult?
        do {
            aggregate = try await summarizedDirectorySize(
                url: url,
                usePhysicalSize: usePhysicalSize,
                cancellation: cancellation,
                summaryLimiter: summaryLimiter,
                detailBudget: detailBudget,
                limits: limits,
                mainDiskOnly: mainDiskOnly
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            aggregate = nil
        }
        let node = FileNode(
            url: url,
            name: values.name,
            isDirectory: true,
            isPackage: values.isPackage ?? false,
            size: aggregate?.size ?? 0
        )
        if aggregate?.isComplete != true || showPackageContents || !node.isPackage {
            node.children = [summaryNode(size: node.size, complete: aggregate?.isComplete == true)]
            node.children[0].parent = node
        }
        return node
    }

    private nonisolated static func summarizedDirectorySize(
        url: URL,
        usePhysicalSize: Bool,
        cancellation: CancellationState,
        summaryLimiter: IOLimiter,
        detailBudget: DetailBudget,
        limits: ScanLimits,
        mainDiskOnly: Bool
    ) async throws -> AggregateResult? {
        try await withIOPermit(summaryLimiter) {
            try cancellation.throwIfCancelled()

            let allowedDuration = detailBudget.allowedSummaryDuration(
                maximum: limits.maximumSummaryDuration
            )
            guard allowedDuration > 0 else { return nil }

            let process = Process()
            let output = Pipe()
            let exitState = ProcessExitState()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            var arguments = usePhysicalSize ? ["-skx"] : ["-Askx"]
            for name in summaryExcludedNames(for: url, mainDiskOnly: mainDiskOnly) {
                arguments.append(contentsOf: ["-I", name])
            }
            arguments.append(url.path)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in exitState.signalExit() }
            try process.run()
            guard cancellation.register(process) else {
                await terminate(process, exitState: exitState)
                throw CancellationError()
            }
            defer { cancellation.unregister(process) }

            if !(await exitState.wait(timeout: allowedDuration)) {
                Self.logger.notice(
                    "Aggregate sizing reached its \(allowedDuration, privacy: .public)-second limit for \(url.path, privacy: .private(mask: .hash))"
                )
                await terminate(process, exitState: exitState)
                try cancellation.throwIfCancelled()
                return nil
            }

            try cancellation.throwIfCancelled()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return parseAggregateResult(output: data, terminationStatus: process.terminationStatus)
        }
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

    nonisolated static func isKnownHighCardinalityDirectory(_ url: URL) -> Bool {
        if highCardinalityDirectoryNames.contains(url.lastPathComponent) {
            return true
        }

        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path == home + "/Library/Caches"
            || path == home + "/Library/Developer/Xcode/DerivedData"
            || path == home + "/Library/pnpm/store"
            || path.hasSuffix("/vendor/bundle")
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
        for child in retained.dropFirst(limit) {
            summarizedSize += child.size
            summarizedCount += 1
            summarizedIncomplete = summarizedIncomplete
                || child.containsNode(where: { $0.type == .incompleteSummary })
        }
        retained.removeSubrange(limit...)
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
        maximumDirectoryEntries: 10_000,
        maximumSummaryDuration: 120,
        maximumTotalDuration: 180
    )

    let maximumDetailedNodes: Int
    let maximumDetailedDuration: TimeInterval
    let maximumDirectoryEntries: Int
    let maximumSummaryDuration: TimeInterval
    let maximumTotalDuration: TimeInterval

    init(
        maximumDetailedNodes: Int,
        maximumDetailedDuration: TimeInterval,
        maximumDirectoryEntries: Int,
        maximumSummaryDuration: TimeInterval = 120,
        maximumTotalDuration: TimeInterval = 180
    ) {
        self.maximumDetailedNodes = maximumDetailedNodes
        self.maximumDetailedDuration = maximumDetailedDuration
        self.maximumDirectoryEntries = maximumDirectoryEntries
        self.maximumSummaryDuration = maximumSummaryDuration
        self.maximumTotalDuration = maximumTotalDuration
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

    func allowedSummaryDuration(maximum: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limits.maximumTotalDuration
            - (ProcessInfo.processInfo.systemUptime - startedAt)
        return min(maximum, max(0, remaining))
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
