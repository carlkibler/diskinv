//
//  ContentView.swift
//  DiskInventoryX
//
//  Main application view with NavigationSplitView
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if appState.rootNode == nil && !appState.isScanning {
                WelcomeView()
            } else {
                browserView
            }
        }
        .background {
            WindowSizer()
                .frame(width: 0, height: 0)
        }
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Can't Move to Trash", isPresented: .constant(appState.trashProtectionMessage != nil)) {
            Button("OK") {
                appState.trashProtectionMessage = nil
            }
        } message: {
            Text(appState.trashProtectionMessage ?? "")
        }
        .sheet(isPresented: .constant(!appState.pendingTrashNodes.isEmpty)) {
            TrashConfirmationView(nodes: appState.pendingTrashNodes) {
                appState.cancelMoveToTrash()
            } confirm: {
                appState.confirmMoveToTrash()
            }
        }
    }

    private var browserView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } content: {
            FileListView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 700, max: .infinity)
        } detail: {
            TreeMapContainerView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { appState.showOpenPanel() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open a folder to analyze")
                .disabled(appState.isScanning)

                Divider()

                Button(action: { appState.zoomIn() }) {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom into selected folder")
                .disabled(appState.selectedNode == nil || !(appState.selectedNode?.isDirectory ?? false))

                Button(action: { appState.zoomOut() }) {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom out to parent folder")
                .disabled(appState.zoomStack.isEmpty)

                Button(action: { appState.zoomToRoot() }) {
                    Label("Zoom to Root", systemImage: "arrow.up.to.line")
                }
                .help("Zoom to root folder")
                .disabled(appState.zoomedNode == nil)

                Divider()

                Button(action: {
                    Task { await appState.refresh() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan current folder")
                .disabled(appState.rootNode == nil || appState.isScanning)
            }
        }
        .navigationTitle(navigationTitle)
        .overlay {
            if appState.isScanning {
                ScanningOverlay()
                    .allowsHitTesting(false)
            }
        }
    }

    private var navigationTitle: String {
        if let zoomed = appState.zoomedNode {
            return zoomed.name
        } else if let root = appState.rootNode {
            return root.name
        } else {
            return "Disk Inventory X-Ray"
        }
    }
}

private struct TrashConfirmationView: View {
    let nodes: [FileNode]
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(nodes.count == 1 ? "This Item" : "\(nodes.count) Items") to Trash?")
                .font(.title2.weight(.semibold))

            Text("The selected items will be moved to the Trash.")
                .foregroundStyle(.secondary)

            Table(nodes) {
                TableColumn("Item") { node in
                    Text(node.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Size") { node in
                    Text(FileSizeFormatter.string(from: node.size))
                        .monospacedDigit()
                }
                .width(90)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 360)
        .interactiveDismissDisabled()
    }
}

private struct WindowSizer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            resize(view.window, context: context)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            resize(view.window, context: context)
        }
    }

    private func resize(_ window: NSWindow?, context: Context) {
        guard let window, !context.coordinator.hasSizedWindow else { return }
        context.coordinator.hasSizedWindow = true
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.center()
    }

    final class Coordinator {
        var hasSizedWindow = false
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ContentUnavailableView {
            Text("Choose What to Scan")
                .font(.title.weight(.semibold))
        } description: {
            Text("Scan your user folder, your main disk, or another directory.")
                .frame(width: 380)
        } actions: {
            VStack(spacing: 10) {
                Button {
                    Task {
                        await appState.scanPreset(url: FileManager.default.homeDirectoryForCurrentUser)
                    }
                } label: {
                    Text("User Folder (\(FileManager.default.homeDirectoryForCurrentUser.path))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await appState.scanPreset(url: URL(fileURLWithPath: "/", isDirectory: true))
                    }
                } label: {
                    Text("Entire Main Disk")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    appState.showOpenPanel()
                } label: {
                    Text("Choose Directory…")
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 280)
        }
    }
}

// MARK: - Scanning Overlay

struct ScanningOverlay: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Scanning...")
                    .font(.headline)

                Text("Large caches and system folders are sized in the background once the tree appears.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = appState.scanProgress {
                    VStack(spacing: 4) {
                        Text(progress.currentFolder)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("\(progress.filesScanned) files, \(progress.foldersScanned) folders")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(24)
            .frame(width: 460)
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - TreeMap Container

struct TreeMapContainerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot {
                TreeMapView(
                    root: root,
                    selectedNode: $appState.selectedNode,
                    colorProvider: { appState.color(for: $0) }
                )
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
