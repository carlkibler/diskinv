//
//  FileListView.swift
//  DiskInventoryX
//
//  Outline view showing file hierarchy
//

import SwiftUI
import AppKit

struct FileListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot, !root.children.isEmpty {
                VStack(spacing: 0) {
                    FileOutlineView(root: root, generation: appState.treeGeneration)
                    if appState.pendingSummaryCount > 0 {
                        BackgroundSizingBar(remaining: appState.pendingSummaryCount)
                    }
                }
            } else if appState.displayRoot != nil {
                ContentUnavailableView(
                    "Folder Is Empty",
                    systemImage: "folder",
                    description: Text("This folder contains no visible files")
                )
            } else {
                Color.clear
            }
        }
        .navigationTitle("Files")
    }
}

private struct BackgroundSizingBar: View {
    let remaining: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Sizing \(remaining) \(remaining == 1 ? "folder" : "folders") in the background…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Outline

/// AppKit outline so the tree gets native keyboard handling: arrows move, left and right
/// collapse and expand, Option-Right expands a whole subtree, typing jumps to a name.
struct FileOutlineView: NSViewRepresentable {
    let root: FileNode
    let generation: Int
    @EnvironmentObject private var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.zoomIntoClickedRow(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.outlineView = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.appState = appState
        if coordinator.root !== root || coordinator.generation != generation {
            let rootChanged = coordinator.root !== root
            coordinator.root = root
            coordinator.generation = generation
            coordinator.outlineView?.reloadData()
            if rootChanged, let outline = coordinator.outlineView {
                DispatchQueue.main.async {
                    outline.window?.makeFirstResponder(outline)
                }
            }
        }
        coordinator.syncSelection(to: appState.selectedNode)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var appState: AppState
        var root: FileNode?
        var generation = 0
        weak var outlineView: NSOutlineView?
        private var isSyncingSelection = false
        private let cellIdentifier = NSUserInterfaceItemIdentifier("FileRowCell")

        init(appState: AppState) {
            self.appState = appState
        }

        private func node(for item: Any?) -> FileNode? {
            item == nil ? root : item as? FileNode
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(for: item)?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(for: item)!.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? FileNode)?.children.isEmpty ?? true)
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: cellIdentifier, owner: nil) as? FileRowCellView
                ?? FileRowCellView(identifier: cellIdentifier)
            cell.configure(node: node, appState: appState)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileNode)?.name
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
            MainActor.assumeIsolated {
                appState.selectedNodes = Set(nodes)
                appState.selectedNode = nodes.first
            }
        }

        @objc func zoomIntoClickedRow(_ sender: Any?) {
            guard let outlineView, outlineView.clickedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode,
                  node.isDirectory, !node.children.isEmpty else { return }
            MainActor.assumeIsolated {
                appState.selectedNode = node
                appState.zoomIn()
            }
        }

        // MARK: Selection sync

        /// Mirrors a selection made elsewhere (the treemap, a deletion) into the outline,
        /// expanding ancestors so the row is visible.
        @MainActor
        func syncSelection(to node: FileNode?) {
            guard let outlineView, !isSyncingSelection else { return }
            let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }

            guard let node else {
                if !selected.isEmpty {
                    isSyncingSelection = true
                    outlineView.deselectAll(nil)
                    isSyncingSelection = false
                }
                return
            }
            guard !selected.contains(where: { $0 === node }) else { return }

            var ancestors: [FileNode] = []
            var current = node.parent
            while let ancestor = current, ancestor !== root {
                ancestors.insert(ancestor, at: 0)
                current = ancestor.parent
            }
            guard current === root else { return }

            isSyncingSelection = true
            defer { isSyncingSelection = false }
            ancestors.forEach { outlineView.expandItem($0) }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            if appState.selectedNodes != [node] {
                let appState = appState
                DispatchQueue.main.async { appState.selectedNodes = [node] }
            }
        }
    }
}

/// Hosts the SwiftUI row inside an AppKit cell so the row keeps its context menu and size bar.
private final class FileRowCellView: NSTableCellView {
    private let hostingView: NSHostingView<AnyView>
    private var node: FileNode?
    private weak var appState: AppState?

    init(identifier: NSUserInterfaceItemIdentifier) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = identifier
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(node: FileNode, appState: AppState) {
        self.node = node
        self.appState = appState
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    private func render() {
        guard let node, let appState else { return }
        hostingView.rootView = AnyView(
            FileRow(node: node, emphasized: backgroundStyle == .emphasized)
                .environmentObject(appState)
        )
    }
}

// MARK: - Row

struct FileRow: View {
    let node: FileNode
    var emphasized = false
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 16, height: 16)

            // Name
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Kind (for non-folders and folders shown as one block)
            if !node.isDirectory || node.isSummarized {
                Text(node.kindName)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Size
            Text(node.isSizePending ? "sizing…" : FileSizeFormatter.string(from: node.size))
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            // Size bar
            SizeBar(
                size: node.size,
                maxSize: appState.displayRoot?.size ?? node.size,
                color: appState.color(for: node.kindName)
            )
            .frame(width: 60)
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .contextMenu {
            FileNodeContextMenu(
                node: node,
                zoomAction: node.isDirectory && !node.children.isEmpty ? {
                    appState.selectedNode = node
                    appState.zoomIn()
                } : nil,
                trashAction: {
                    appState.moveToTrash(node)
                }
            )
        }
    }
}

struct FileNodeContextMenu: View {
    let node: FileNode
    let zoomAction: (() -> Void)?
    let trashAction: (() -> Void)?

    var body: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
        }
        .disabled(node.isSpecialItem)

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        .disabled(node.isSpecialItem)

        if node.isDirectory {
            Button("Open in Terminal") {
                openInTerminal(node.url)
            }
            .disabled(node.isSpecialItem)

            if let zoomAction {
                Button("Zoom Into", action: zoomAction)
            }
        }

        if let trashAction {
            Divider()

            Button("Move to Trash", role: .destructive, action: trashAction)
                .disabled(node.isSpecialItem)
        }
    }

    private func openInTerminal(_ directory: URL) {
        let workspace = NSWorkspace.shared

        if let ghostty = workspace.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--working-directory=\(directory.path)"]
            configuration.createsNewApplicationInstance = true
            workspace.openApplication(at: ghostty, configuration: configuration) { _, error in
                if error != nil {
                    openInAppleTerminal(directory)
                }
            }
            return
        }

        openInAppleTerminal(directory)
    }

    private func openInAppleTerminal(_ directory: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }

        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

struct SizeBar: View {
    let size: UInt64
    let maxSize: UInt64
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = maxSize > 0 ? CGFloat(size) / CGFloat(maxSize) : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))

                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

#Preview {
    let appState = AppState()

    let root = FileNode(url: URL(fileURLWithPath: "/"), name: "Root", isDirectory: true, size: 1000)
    let folder = FileNode(url: URL(fileURLWithPath: "/folder"), name: "Documents", isDirectory: true, size: 600)
    let file1 = FileNode(url: URL(fileURLWithPath: "/folder/a.txt"), name: "readme.txt", size: 100)
    let file2 = FileNode(url: URL(fileURLWithPath: "/folder/b.pdf"), name: "report.pdf", size: 500)
    folder.children = [file1, file2]
    let file3 = FileNode(url: URL(fileURLWithPath: "/c.app"), name: "App.app", isPackage: true, size: 400)
    root.children = [folder, file3]

    return FileListView()
        .environmentObject(appState)
        .frame(width: 400, height: 300)
        .onAppear {
            appState.rootNode = root
        }
}
