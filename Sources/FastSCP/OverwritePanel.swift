import AppKit
import SwiftUI
import FastSCPCore

/// Confirms remote overwrite before a send. scp transfers the whole batch in a
/// single invocation and cannot prompt per-file, so this lists every collision
/// up front with per-item checkboxes (default all checked); the user picks
/// which to overwrite, and those entries are removed on the remote first so scp
/// can recreate them (a read-only existing file would otherwise fail).
@MainActor
final class OverwritePanelController {
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?
    private var continuation: CheckedContinuation<Set<String>?, Never>?
    private var finished = false
    private let viewModel: OverwriteViewModel

    private init(collisions: [RemoteEntry]) {
        self.viewModel = OverwriteViewModel(
            collisions: collisions,
            selected: Set(collisions.map(\.name)))
    }

    /// Present the overwrite confirmation. `nil` = cancelled; non-empty = the
    /// remote entry names the user chose to overwrite.
    static func prompt(alias: String, path: String, collisions: [RemoteEntry]) async -> Set<String>? {
        let controller = OverwritePanelController(collisions: collisions)
        return await controller.show(alias: alias, path: path)
    }

    private func show(alias: String, path: String) async -> Set<String>? {
        await withCheckedContinuation { (cont: CheckedContinuation<Set<String>?, Never>) in
            self.continuation = cont

            let host = NSHostingController(rootView:
                OverwriteView(alias: alias, path: path, viewModel: viewModel,
                              onCancel: { [weak self] in self?.finish(nil) },
                              onConfirm: { [weak self] in self?.finish(self?.viewModel.selected) }))

            let panel = NSPanel(contentViewController: host)
            panel.title = "覆盖确认"
            panel.styleMask = [.titled, .closable]
            panel.setContentSize(NSSize(width: 380, height: 320))
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            self.panel = panel

            // Closing the window (the × button) counts as cancel.
            self.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finish(nil) }
            }

            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Resume exactly once with the chosen names (nil = cancelled). Idempotent —
    /// the confirm button, cancel button, and window-close all funnel here.
    private func finish(_ result: Set<String>?) {
        guard !finished else { return }
        finished = true
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        panel?.close()
        panel = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }
}

@MainActor
final class OverwriteViewModel: ObservableObject {
    @Published var selected: Set<String>
    let collisions: [RemoteEntry]
    init(collisions: [RemoteEntry], selected: Set<String>) {
        self.collisions = collisions
        self.selected = selected
    }
}

private struct OverwriteView: View {
    let alias: String
    let path: String
    @ObservedObject var viewModel: OverwriteViewModel
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("远程「\(alias):\(path)」已存在以下同名项目，是否覆盖？")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(viewModel.collisions) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.selected.contains(entry.name)
                              ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.tint)
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        Text(entry.name).truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(entry.name) }
                }
            }
            .frame(minHeight: 120, maxHeight: 240)

            HStack {
                Button("全选") { viewModel.selected = Set(viewModel.collisions.map(\.name)) }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("全不选") { viewModel.selected = [] }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button(viewModel.selected.isEmpty ? "覆盖选中" : "覆盖选中 (\(viewModel.selected.count))") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selected.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func toggle(_ name: String) {
        if viewModel.selected.contains(name) { viewModel.selected.remove(name) }
        else { viewModel.selected.insert(name) }
    }
}

/// Orchestrates overwrite resolution for a send: detect remote collisions,
/// prompt the user, and clear the chosen entries before the transfer runs.
/// Used by both the quick-send (headless HUD) and destination-panel send paths.
@MainActor
enum SendOverwrite {
    enum Resolution {
        case proceed           // no collisions, or chosen entries removed — go ahead
        case cancelled         // user dismissed the dialog
        case failed(String)    // removing the entries failed
    }

    static func resolve(alias: String, path: String, sources: [URL]) async -> Resolution {
        // Detect collisions: remote entries whose name matches a source name.
        let remote: [RemoteEntry]
        do {
            remote = try await SSHExecutor.shared.listEntries(alias: alias, path: path)
        } catch {
            DiagLog.log("[overwrite] listEntries failed (\(error)); proceeding best-effort")
            return .proceed
        }
        let sourceNames = Set(sources.map(\.lastPathComponent))
        let collisions = remote.filter { sourceNames.contains($0.name) }
        DiagLog.log("[overwrite] alias=\(alias) path=\(path) collisions=\(collisions.map(\.name))")
        guard !collisions.isEmpty else { return .proceed }

        guard let chosen = await OverwritePanelController.prompt(alias: alias, path: path, collisions: collisions),
              !chosen.isEmpty else {
            return .cancelled
        }
        let rm = await SSHExecutor.shared.removeRemoteEntries(alias: alias, path: path, names: Array(chosen))
        if !rm.success {
            return .failed(SSHErrorMapper.friendlyMessage(for: SSHError.transferFailed(stderr: rm.message)))
        }
        return .proceed
    }
}
