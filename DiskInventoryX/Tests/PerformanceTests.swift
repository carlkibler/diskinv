//
//  PerformanceTests.swift
//  DiskInventoryXTests
//

import XCTest
@testable import DiskInventoryX

final class FileScannerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryXTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testScanBuildsNestedTreeWithLogicalSizes() async throws {
        let nested = temporaryDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 17).write(to: nested.appendingPathComponent("small.txt"))
        try Data(repeating: 0x02, count: 31).write(to: nested.appendingPathComponent("large.bin"))

        let scanner = FileScanner()
        let root = try await scanner.scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            progress: { _, _, _ in }
        )

        let nestedNode = try XCTUnwrap(root.children.first { $0.name == "nested" })
        XCTAssertEqual(nestedNode.size, 48)
        XCTAssertEqual(nestedNode.children.map(\.name).sorted(), ["large.bin", "small.txt"])
        XCTAssertEqual(root.size, 48)
    }

    func testScanDoesNotDescendIntoPackagesOrSymlinks() async throws {
        let package = temporaryDirectory.appendingPathComponent("sample.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("package child".utf8).write(to: package.appendingPathComponent("inside.txt"))

        let target = temporaryDirectory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("symlink child".utf8).write(to: target.appendingPathComponent("inside.txt"))
        let symlink = temporaryDirectory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let scanner = FileScanner()
        let root = try await scanner.scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            progress: { _, _, _ in }
        )

        let packageNode = try XCTUnwrap(root.children.first { $0.name == "sample.bundle" })
        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.children.isEmpty)
        XCTAssertGreaterThanOrEqual(packageNode.size, 13)

        let linkNode = try XCTUnwrap(root.children.first { $0.name == "linked" })
        XCTAssertTrue(linkNode.children.isEmpty)
    }

    func testKnownHighCardinalityTreeUsesFastAggregateSize() async throws {
        let dependencyTree = temporaryDirectory.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyTree, withIntermediateDirectories: true)
        try Data(repeating: 0x03, count: 4_096).write(to: dependencyTree.appendingPathComponent("index.js"))

        var filesReported = 0
        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            progress: { _, files, _ in filesReported = files }
        )

        let dependencies = try XCTUnwrap(root.children.first { $0.name == "node_modules" })
        XCTAssertGreaterThanOrEqual(dependencies.size, 4_096)
        XCTAssertEqual(dependencies.children.count, 1)
        XCTAssertEqual(dependencies.children.first?.type, .summary)
        XCTAssertEqual(dependencies.children.first?.size, dependencies.size)
        XCTAssertEqual(filesReported, 0)
    }

    func testAggregateSizingStopsAtTheScanLimit() async throws {
        let dependencyTree = temporaryDirectory.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyTree, withIntermediateDirectories: true)
        try Data(repeating: 0x06, count: 4_096).write(to: dependencyTree.appendingPathComponent("index.js"))

        let startedAt = ProcessInfo.processInfo.systemUptime
        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            limits: ScanLimits(
                maximumDetailedNodes: 1_000,
                maximumDetailedDuration: 60,
                maximumDirectoryEntries: 10_000,
                maximumSummaryDuration: 0,
                maximumTotalDuration: 60
            ),
            progress: { _, _, _ in }
        )

        let dependencies = try XCTUnwrap(root.children.first { $0.name == "node_modules" })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1)
        XCTAssertEqual(dependencies.size, 0)
        XCTAssertEqual(dependencies.children.first?.name, "Contents not sized before the scan limit")
        XCTAssertEqual(dependencies.children.first?.type, .incompleteSummary)
    }

    func testStandardScanAllowsANormalHomeDirectoryBeforeSummarizing() {
        XCTAssertGreaterThanOrEqual(ScanLimits.standard.maximumDetailedNodes, 1_000_000)
        XCTAssertTrue(ScanLimits.standard.maximumDetailedDuration.isInfinite)
    }

    func testUserDataIsScannedBeforeSystemBranches() {
        let ordered = FileScanner.prioritizedUserData(in: [
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/Users")
        ])

        XCTAssertEqual(ordered.map(\.path), ["/Users", "/System", "/Library"])
    }

    func testParseableAggregateOutputWithNonzeroExitIsIncomplete() {
        let result = FileScanner.parseAggregateResult(
            output: Data("401931272 /Users\n".utf8),
            terminationStatus: 1
        )

        XCTAssertEqual(result, AggregateResult(size: 401_931_272 * 1_024, isComplete: false))
    }

    func testParseableAggregateOutputWithZeroExitIsComplete() {
        let result = FileScanner.parseAggregateResult(
            output: Data("4 /tmp/example\n".utf8),
            terminationStatus: 0
        )

        XCTAssertEqual(result, AggregateResult(size: 4_096, isComplete: true))
    }

    func testDetailedScanBudgetFallsBackToAggregateSize() async throws {
        let ordinaryTree = temporaryDirectory.appendingPathComponent("ordinary/a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryTree, withIntermediateDirectories: true)
        try Data(repeating: 0x04, count: 2_048).write(to: ordinaryTree.appendingPathComponent("item"))

        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            limits: ScanLimits(
                maximumDetailedNodes: 2,
                maximumDetailedDuration: 60,
                maximumDirectoryEntries: 10_000
            ),
            progress: { _, _, _ in }
        )

        let ordinary = try XCTUnwrap(root.children.first { $0.name == "ordinary" })
        XCTAssertGreaterThanOrEqual(ordinary.size, 2_048)
        XCTAssertEqual(ordinary.children.first?.type, .summary)
        XCTAssertEqual(ordinary.children.first?.size, ordinary.size)
    }

    func testImmediateBranchesHaveIndependentDetailedBudgets() async throws {
        for name in ["first", "second"] {
            let directory = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x07, count: 32).write(to: directory.appendingPathComponent("item"))
        }

        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            limits: ScanLimits(
                maximumDetailedNodes: 2,
                maximumDetailedDuration: 60,
                maximumDirectoryEntries: 10_000
            ),
            progress: { _, _, _ in }
        )

        XCTAssertEqual(root.children.count, 2)
        XCTAssertTrue(root.children.allSatisfy { $0.children.first?.name == "item" })
    }

    func testSelectedRootKeepsItsImmediateBreakdown() async throws {
        for index in 0..<3 {
            try Data(repeating: 0x05, count: 1_024).write(
                to: temporaryDirectory.appendingPathComponent("item-\(index)")
            )
        }

        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            limits: ScanLimits(
                maximumDetailedNodes: 1_000,
                maximumDetailedDuration: 60,
                maximumDirectoryEntries: 2
            ),
            progress: { _, _, _ in }
        )

        XCTAssertGreaterThanOrEqual(root.size, 3_072)
        XCTAssertEqual(root.children.count, 3)
        XCTAssertEqual(Set(root.children.map(\.name)), ["item-0", "item-1", "item-2"])
    }

    func testHighCardinalityPolicyCoversRepositoriesAndDependencyCaches() {
        XCTAssertTrue(FileScanner.isKnownHighCardinalityDirectory(URL(fileURLWithPath: "/tmp/repo/.git")))
        XCTAssertTrue(FileScanner.isKnownHighCardinalityDirectory(URL(fileURLWithPath: "/tmp/repo/.venv")))
        XCTAssertTrue(FileScanner.isKnownHighCardinalityDirectory(URL(fileURLWithPath: "/tmp/repo/Pods")))
        XCTAssertFalse(FileScanner.isKnownHighCardinalityDirectory(URL(fileURLWithPath: "/tmp/repo/Sources")))
    }

    func testScanIncludesHiddenFiles() async throws {
        try Data(repeating: 0, count: 23).write(to: temporaryDirectory.appendingPathComponent(".hidden-data"))

        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            progress: { _, _, _ in }
        )

        XCTAssertEqual(root.children.first { $0.name == ".hidden-data" }?.size, 23)
    }

    func testMainDiskScanCompactsSmallDescendants() async throws {
        let outer = temporaryDirectory.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data(repeating: 0, count: 32).write(to: inner.appendingPathComponent(".hidden-\(index)"))
        }

        let root = try await FileScanner().scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            mainDiskOnly: true,
            progress: { _, _, _ in }
        )

        let innerNode = try XCTUnwrap(root.children.first?.children.first)
        XCTAssertEqual(innerNode.size, 640)
        XCTAssertEqual(innerNode.children.count, 1)
        XCTAssertEqual(innerNode.children.first?.type, .summary)
        XCTAssertEqual(innerNode.children.first?.size, 640)
    }

    func testProgressReportsDirectoriesAndMonotonicTotals() async throws {
        let first = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let second = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let scanner = FileScanner()
        var progress: [(files: Int, folders: Int)] = []
        _ = try await scanner.scan(
            url: temporaryDirectory,
            showPackageContents: false,
            usePhysicalSize: false,
            progress: { _, files, folders in progress.append((files, folders)) }
        )

        XCTAssertFalse(progress.isEmpty)
        XCTAssertTrue(progress.allSatisfy { $0.files >= 0 && $0.folders >= 1 })
        let sortedProgress = progress.sorted { lhs, rhs in
            lhs.files == rhs.files ? lhs.folders <= rhs.folders : lhs.files <= rhs.files
        }
        XCTAssertEqual(progress.map { "\($0.files):\($0.folders)" }, sortedProgress.map { "\($0.files):\($0.folders)" })
    }

    func testCancellationIsPropagated() async throws {
        for index in 0..<300 {
            let child = temporaryDirectory.appendingPathComponent(String(format: "%03d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 8).write(to: child.appendingPathComponent("item"))
        }

        let scanner = FileScanner()
        let cancellationApplied = DispatchSemaphore(value: 0)
        do {
            _ = try await scanner.scan(
                url: temporaryDirectory,
                showPackageContents: false,
                usePhysicalSize: false,
                progress: { _, _, _ in
                    Task {
                        await scanner.cancel()
                        cancellationApplied.signal()
                    }
                    _ = cancellationApplied.wait(timeout: .now() + 2)
                }
            )
            XCTFail("scan should report cancellation")
        } catch is CancellationError {
            // The first callback blocks until cancel() has reached the actor.
        }
    }

    func testMainDiskScanSkipsCloudAndMountedVolumes() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertTrue(FileScanner.shouldSkipDuringMainDiskScan(
            url: URL(fileURLWithPath: "/System/Volumes/Data"),
            volumeURL: URL(fileURLWithPath: "/System/Volumes/Data")
        ))
        XCTAssertTrue(FileScanner.shouldSkipDuringMainDiskScan(
            url: home.appendingPathComponent("Library/CloudStorage/OneDrive-Corporate"),
            volumeURL: URL(fileURLWithPath: "/")
        ))
        XCTAssertTrue(FileScanner.shouldSkipDuringMainDiskScan(
            url: home.appendingPathComponent("UnknownMount"),
            volumeURL: nil
        ))
        XCTAssertFalse(FileScanner.shouldSkipDuringMainDiskScan(
            url: home.appendingPathComponent("Documents"),
            volumeURL: URL(fileURLWithPath: "/")
        ))
    }

    func testMainDiskScanSkipsRootLookupNamespaces() throws {
        for path in ["/.file", "/.nofollow", "/.resolve", "/.vol"] {
            XCTAssertTrue(FileScanner.shouldSkipDuringMainDiskScan(
                url: URL(fileURLWithPath: path, isDirectory: true),
                volumeURL: URL(fileURLWithPath: "/")
            ))
        }

        let rootEntries = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/"),
            includingPropertiesForKeys: [],
            options: []
        )
        let nofollow = try XCTUnwrap(rootEntries.first { $0.lastPathComponent == ".nofollow" })
        XCTAssertTrue(FileScanner.shouldSkipDuringMainDiskScan(
            url: nofollow,
            volumeURL: URL(fileURLWithPath: "/")
        ))

        XCTAssertFalse(FileScanner.shouldSkipDuringMainDiskScan(
            url: URL(fileURLWithPath: "/Users/example/.nofollow"),
            volumeURL: URL(fileURLWithPath: "/")
        ))
    }

    func testLiveMainDiskScanRespectsItsDeadline() async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let root = try await FileScanner().scan(
            url: URL(fileURLWithPath: "/"),
            showPackageContents: false,
            usePhysicalSize: false,
            mainDiskOnly: true,
            limits: ScanLimits(
                maximumDetailedNodes: 5_000,
                maximumDetailedDuration: 1,
                maximumDirectoryEntries: 10_000,
                maximumSummaryDuration: 2,
                maximumTotalDuration: 5
            ),
            progress: { _, _, _ in }
        )

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 12)
        XCTAssertTrue(root.children.allSatisfy {
            ![".file", ".nofollow", ".resolve", ".vol"].contains($0.name)
        })
    }

    func testMainDiskAggregateExclusionsAreScopedToTheirRealParents() {
        XCTAssertEqual(
            FileScanner.summaryExcludedNames(for: URL(fileURLWithPath: "/System"), mainDiskOnly: true),
            ["Volumes"]
        )
        XCTAssertEqual(
            Set(FileScanner.summaryExcludedNames(
                for: URL(fileURLWithPath: "/Users"),
                mainDiskOnly: true
            )),
            ["CloudStorage", "Mobile Documents"]
        )
        XCTAssertTrue(FileScanner.summaryExcludedNames(
            for: URL(fileURLWithPath: "/Users/carl/Documents/Volumes"),
            mainDiskOnly: true
        ).isEmpty)
    }
}

final class TreeMapLayoutTests: XCTestCase {
    func testLayoutIsRepeatableAndFitsCanvas() {
        let root = FileNode(url: URL(fileURLWithPath: "/tmp/root"), name: "root", isDirectory: true, size: 100)
        let large = FileNode(url: URL(fileURLWithPath: "/tmp/large"), name: "large", size: 60)
        let folder = FileNode(url: URL(fileURLWithPath: "/tmp/folder"), name: "folder", isDirectory: true, size: 40)
        let nested = FileNode(url: URL(fileURLWithPath: "/tmp/nested"), name: "nested", size: 40)
        folder.children = [nested]
        folder.children.forEach { $0.parent = folder }
        root.children = [folder, large]
        root.children.forEach { $0.parent = root }

        let canvas = CGRect(x: 0, y: 0, width: 400, height: 200)
        let first = TreeMapLayout.layout(node: root, rect: canvas, colorProvider: { _ in .blue })
        let second = TreeMapLayout.layout(node: root, rect: canvas, colorProvider: { _ in .blue })

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map { $0.node.name }, second.map { $0.node.name })
        XCTAssertEqual(first.map(\.rect), second.map(\.rect))
        XCTAssertTrue(first.allSatisfy { canvas.contains($0.rect) })
        XCTAssertTrue(first.allSatisfy { $0.rect.width >= 2 && $0.rect.height >= 2 })
    }

    func testZeroSizeChildrenDoNotProduceRectangles() {
        let root = FileNode(url: URL(fileURLWithPath: "/tmp/root"), isDirectory: true, size: 10)
        let nonEmpty = FileNode(url: URL(fileURLWithPath: "/tmp/file"), name: "file", size: 10)
        let empty = FileNode(url: URL(fileURLWithPath: "/tmp/empty"), name: "empty", size: 0)
        root.children = [nonEmpty, empty]

        let rects = TreeMapLayout.layout(node: root, rect: CGRect(x: 0, y: 0, width: 100, height: 100), colorProvider: { _ in .red })

        XCTAssertEqual(rects.map { $0.node.name }, ["file"])
    }
}

@MainActor
final class TrashProtectionTests: XCTestCase {
    func testProtectsSystemAndTopLevelUserFolders() {
        let appState = AppState()
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertTrue(appState.isProtectedFromTrash(URL(fileURLWithPath: "/System/Library"), isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(home, isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(home.appendingPathComponent("Documents"), isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(home.appendingPathComponent("Music"), isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(URL(fileURLWithPath: "/var/db"), isDirectory: true))
        XCTAssertTrue(appState.isProtectedFromTrash(URL(fileURLWithPath: "/etc"), isDirectory: true))
    }

    func testAllowsOrdinaryFoldersAndFiles() {
        let appState = AppState()
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertFalse(appState.isProtectedFromTrash(home.appendingPathComponent("Projects/old-build"), isDirectory: true))
        XCTAssertFalse(appState.isProtectedFromTrash(home.appendingPathComponent("Documents/large.zip"), isDirectory: false))
    }

    func testDeletionSelectsNextSiblingThenPreviousSibling() {
        let appState = AppState()
        let parent = FileNode(url: URL(fileURLWithPath: "/tmp/parent"), isDirectory: true)
        let first = FileNode(url: URL(fileURLWithPath: "/tmp/parent/first"))
        let second = FileNode(url: URL(fileURLWithPath: "/tmp/parent/second"))
        let third = FileNode(url: URL(fileURLWithPath: "/tmp/parent/third"))
        parent.children = [first, second, third]
        parent.children.forEach { $0.parent = parent }

        XCTAssertTrue(appState.nextSelection(afterDeleting: [second]) === third)
        XCTAssertTrue(appState.nextSelection(afterDeleting: [second, third]) === first)
    }

    func testUnscannedSizeSaturatesAccountingDifferences() {
        let appState = AppState()

        XCTAssertEqual(appState.unscannedSize(total: 1_000, free: 400, scanned: 250), 350)
        XCTAssertEqual(appState.unscannedSize(total: 1_000, free: 400, scanned: 700), 0)
        XCTAssertEqual(appState.unscannedSize(total: 400, free: 500, scanned: 0), 0)
    }
}
