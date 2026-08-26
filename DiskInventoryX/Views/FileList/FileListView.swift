//
//  FileListView.swift
//  DiskInventoryX
//
//  Outline view showing file hierarchy
//

import SwiftUI

struct FileListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot, !root.children.isEmpty {
                List(selection: $appState.selectedNodes) {
                    OutlineGroup(root.children, children: \.optionalChildren) { node in
                        FileRow(node: node)
                            .tag(node)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: appState.selectedNodes) { selections in
                    appState.selectedNode = selections.first
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

struct FileRow: View {
    let node: FileNode
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

            // Kind (for non-folders)
            if !node.isDirectory {
                Text(node.kindName)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Size
            Text(FileSizeFormatter.string(from: node.size))
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
        .padding(.vertical, 2)
        .contextMenu {
            FileNodeContextMenu(
                node: node,
                zoomAction: node.isDirectory ? {
                    appState.selectedNode = node
                    appState.zoomIn()
                } : nil,
                trashAction: {
                    moveToTrash(node)
                }
            )
        }
    }

    private func moveToTrash(_ node: FileNode) {
        appState.moveToTrash(node)
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

// MARK: - FileNode Extension

extension FileNode {
    /// Returns children for OutlineGroup, or nil if no children
    var optionalChildren: [FileNode]? {
        children.isEmpty ? nil : children
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
