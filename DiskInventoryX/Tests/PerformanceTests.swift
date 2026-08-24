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

        let linkNode = try XCTUnwrap(root.children.first { $0.name == "linked" })
        XCTAssertTrue(linkNode.children.isEmpty)
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
}
