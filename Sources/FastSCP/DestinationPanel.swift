import AppKit
import SwiftUI
import FastSCPCore

@MainActor
final class DestinationViewModel: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var selectedAlias: String = ""
    @Published var currentPath: String = "~"
    @Published var entries: [RemoteEntry] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var progressText: String?

    let selections: [URL]
    var onClose: (() -> Void)?

    init(selections: [URL]) {
        self.selections = selections
    }

    func loadHosts() async {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let parsed = SSHConfigParser.parse(text)
        hosts = parsed
        // Default to the most-recent (alias, remotePath) if any history exists;
        // otherwise fall back to the first host's alias and the home directory.
        let last = RecentStore.shared().load().first
        selectedAlias = last?.alias ?? parsed.first?.alias ?? ""
        if let last {
            currentPath = last.remotePath
        }
        await refresh()
    }

    func refresh() async {
        guard !selectedAlias.isEmpty else { return }
        loading = true
        errorMessage = nil
        do {
            entries = try await SSHExecutor.shared.listDirectory(alias: selectedAlias, path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
        loading = false
    }

    func enter(_ entry: RemoteEntry) {
        currentPath = (currentPath as NSString).appendingPathComponent(entry.name)
        Task { await refresh() }
    }

    func goUp() {
        if currentPath == "~" || currentPath == "/" { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
        Task { await refresh() }
    }

    func resetForServerChange() {
        currentPath = "~"
        Task { await refresh() }
    }

    func send() {
        guard !selectedAlias.isEmpty else { return }
        Task { await performTransfer(alias: selectedAlias, path: currentPath) }
    }

    func performTransfer(alias: String, path: String) async {
        progressText = "传输中…"
        defer { progressText = nil }
        do {
            try await SSHExecutor.shared.transfer(alias: alias, path: path, sources: selections) { [weak self] p in
                Task { @MainActor in
                    self?.progressText = p.map { "\($0.percent)% \($0.detail)" } ?? "传输中…"
                }
            }
            RecentStore.shared().record(.init(alias: alias, remotePath: path, timestamp: Date()))
            Notifier.send(title: "FastSCP", body: "已发送 \(selections.count) 项到 \(alias):\(path)")
            onClose?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DestinationView: View {
    @ObservedObject var viewModel: DestinationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("服务器").frame(width: 48, alignment: .leading)
                Picker("服务器", selection: $viewModel.selectedAlias) {
                    ForEach(viewModel.hosts) { Text($0.alias).tag($0.alias) }
                }
                .labelsHidden()
                .onChange(of: viewModel.selectedAlias) { _, _ in
                    viewModel.resetForServerChange()
                }
            }
            HStack {
                Text("路径").frame(width: 48, alignment: .leading)
                TextField("/目标路径", text: $viewModel.currentPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await viewModel.refresh() } }
            }
            Divider()
            content
            if let err = viewModel.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            Spacer(minLength: 0)
            footer
            if let p = viewModel.progressText {
                Text(p).font(.caption).monospacedDigit()
            }
        }
        .padding(12)
        .frame(width: 360, height: 440)
        .task { await viewModel.loadHosts() }
    }

    @ViewBuilder private var content: some View {
        if viewModel.loading {
            ProgressView("读取目录…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.tint)
                    Text(entry.name).truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { viewModel.enter(entry) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("返回上层") { viewModel.goUp() }
            Spacer()
            Button("取消", role: .cancel) { onClose() }
            Button("发送 \(viewModel.selections.count) 项 → \(viewModel.selectedAlias):\(viewModel.currentPath)") {
                viewModel.send()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedAlias.isEmpty || viewModel.progressText != nil)
        }
    }
}

@MainActor
final class DestinationPanelController {
    private let panel: NSPanel

    init(selections: [URL], onClose: @escaping () -> Void) {
        let viewModel = DestinationViewModel(selections: selections)
        let closeBox = CloseBox()
        let host = NSHostingController(
            rootView: DestinationView(viewModel: viewModel) {
                closeBox.close()
            }
        )
        let panel = NSPanel(contentViewController: host)
        panel.title = "传送到服务器"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 360, height: 440))
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        self.panel = panel

        let closeAction = { [weak panel] in
            panel?.close()
            onClose()
        }
        closeBox.action = closeAction
        viewModel.onClose = closeAction
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class CloseBox {
    var action: (() -> Void)?
    func close() { action?() }
}
