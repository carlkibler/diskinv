//
//  FileScanner.swift
//  DiskInventoryX
//
//  Async file system scanner
//

import Foundation
import UniformTypeIdentifiers

actor FileScanner {
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
        progress: @escaping (String, Int, Int) -> Void
    ) async throws -> FileNode {
        let cancellation = CancellationState()
        cancellationState = cancellation
        defer { cancellationState = nil }

        let progressState = ProgressState(callback: progress)
        let ioLimiter = IOLimiter(maxConcurrentOperations: Self.maxConcurrentOperations)
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
                parallelizeChildren: true,
                depth: 0
            )
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
        parallelizeChildren: Bool,
        depth: Int
    ) async throws -> FileNode {
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()

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
                        includingPropertiesForKeys: resourceKeyArray,
                        options: []
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Can't enumerate directory, return node with no children.
            return node
        }

        try cancellation.throwIfCancelled()
        try Task.checkCancellation()

        var children: [FileNode] = []
        if parallelizeChildren {
            // Only the root's immediate children run as tasks. Nested branches recurse
            // serially, so a million-file directory cannot create a million suspended tasks.
            try await withThrowingTaskGroup(of: FileNode?.self) { group in
                var nextChildIndex = 0
                func addNextChildTask() {
                    guard nextChildIndex < contents.count else { return }
                    let childURL = contents[nextChildIndex]
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
                                parallelizeChildren: false,
                                depth: depth + 1
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Skip files we can't access (permission denied, etc.).
                            return nil
                        }
                    }
                }

                for _ in 0..<min(Self.maxConcurrentOperations, contents.count) {
                    addNextChildTask()
                }

                while let child = try await group.next() {
                    if let child {
                        child.parent = node
                        children.append(child)
                        node.size += child.size
                    }
                    addNextChildTask()
                }
            }
        } else {
            for childURL in contents {
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
                        parallelizeChildren: false,
                        depth: depth + 1
                    )
                    child.parent = node
                    children.append(child)
                    node.size += child.size
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Skip files we can't access (permission denied, etc.).
                }
            }
        }

        node.children = children
        return node
    }

    private nonisolated static func resourceKeys(usePhysicalSize: Bool) -> Set<URLResourceKey> {
        var keys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .isAliasFileKey
        ]
        if usePhysicalSize {
            keys.insert(.totalFileAllocatedSizeKey)
        }
        return keys
    }

    private nonisolated static func withIOPermit<T>(
        _ ioLimiter: IOLimiter,
        operation: () throws -> T
    ) async throws -> T {
        await ioLimiter.acquire()
        do {
            let result = try operation()
            await ioLimiter.release()
            return result
        } catch {
            await ioLimiter.release()
            throw error
        }
    }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
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
