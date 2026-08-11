import AppKit
import SwiftUI
import FastSCPCore

enum SSHConfigStatus: Equatable {
    case loading
    case ok(hostCount: Int)
    case notFound
    case unreadable
    case empty
}

enum ConnectionStatus: Equatable {
    case idle
    case checking
    case ok
    case failed(message: String)
}

@MainActor
final class DestinationViewModel: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var selectedAlias: String = ""
    @Published var currentPath: String = "~"
    @Published var entries: [RemoteEntry] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var tracker: TransferTracker?
    @Published var configStatus: SSHConfigStatus = .loading
    @Published var connectionStatus: ConnectionStatus = .idle

    let selections: [URL]
    var onClose: (() -> Void)?

    init(selections: [URL]) {
        self.selections = selections
    }

    func loadHosts() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".ssh/config")
        let sshDir = home.appendingPathComponent(".ssh")

        // Check file existence & readability first.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir)
        if !exists {
            configStatus = .notFound
            return
        }
        if isDir.boolValue { configStatus = .unreadable; return }

        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            configStatus = .unreadable
            return
        }
        let parsed = SSHConfigParser.parse(text)
        if parsed.isEmpty {
            configStatus = .empty
            return
        }
        hosts = parsed
        configStatus = .ok(hostCount: parsed.count)

        let last = RecentStore.shared().load().first
        selectedAlias = last?.alias ?? parsed.first?.alias ?? ""
        if let last {
            currentPath = last.remotePath
        }
        await refresh()
    }

    func openSSHConfig() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.open(configURL)
        } else {
            // Create .ssh dir + empty config so there is something to edit.
            let sshDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
            try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: configURL.path, contents: nil)
            NSWorkspace.shared.open(configURL)
        }
    }

    func refresh() async {
        guard !selectedAlias.isEmpty else { return }
        loading = true
        errorMessage = nil
        connectionStatus = .checking
        do {
            entries = try await SSHExecutor.shared.listDirectory(alias: selectedAlias, path: currentPath)
            connectionStatus = .ok
        } catch {
            let friendly = SSHErrorMapper.friendlyMessage(for: error)
            connectionStatus = .failed(message: friendly)
            errorMessage = friendly
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
        connectionStatus = .idle
        Task { await refresh() }
    }

    func send() {
        guard !selectedAlias.isEmpty else { return }
        Task { await performTransfer(alias: selectedAlias, path: currentPath) }
    }

    func performTransfer(alias: String, path: String) async {
        // Resolve remote overwrite collisions before starting the transfer.
        switch await SendOverwrite.resolve(alias: alias, path: path, sources: selections) {
        case .cancelled:
            return
        case .failed(let msg):
            errorMessage = msg
            return
        case .proceed:
            break
        }
        let t = TransferTracker(sendSelections: selections)
        self.tracker = t
        await t.prepare()
        t.start()
        do {
            try await SSHExecutor.shared.transfer(alias: alias, path: path, sources: selections) { p in
                Task { @MainActor in t.ingest(p) }
            }
            t.complete()
            RecentStore.shared().record(.init(alias: alias, remotePath: path, timestamp: Date()))
            Notifier.send(title: "FastSCP", body: "已发送 \(selections.count) 项到 \(alias):\(path)")
            onClose?()
        } catch {
            t.fail(SSHErrorMapper.friendlyMessage(for: error))
        }
    }

    func cancelTransfer() {
        Task { await SSHExecutor.shared.cancel() }
    }
}

struct DestinationView: View {
    @ObservedObject var viewModel: DestinationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if case .ok = viewModel.configStatus {
                if let t = viewModel.tracker {
                    TransferPhaseView(tracker: t,
                                      alias: viewModel.selectedAlias,
                                      path: viewModel.currentPath,
                                      onCancel: { viewModel.cancelTransfer() },
                                      onClose: { onClose() })
                } else {
                    serverPicker
                    pathField
                    Divider()
                    content
                    statusBar
                    if let err = viewModel.errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
                    }
                    Spacer(minLength: 0)
                    footer
                }
            } else {
                configEmptyState
            }
        }
        .padding(12)
        .frame(width: 360, height: 440)
        .task { await viewModel.loadHosts() }
    }

    @ViewBuilder private var serverPicker: some View {
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
    }

    @ViewBuilder private var pathField: some View {
        HStack {
            Text("路径").frame(width: 48, alignment: .leading)
            TextField("/目标路径", text: $viewModel.currentPath)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.refresh() } }
        }
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 6) {
            switch viewModel.connectionStatus {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.mini)
                Text("连接中…").font(.caption2).foregroundStyle(.secondary)
            case .ok:
                Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                Text("已连接").font(.caption2).foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                Text(msg).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if case .ok(let count) = viewModel.configStatus {
                Text("\(count) 台服务器").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var configEmptyState: some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            switch viewModel.configStatus {
            case .notFound:
                Text("未找到 SSH 配置").font(.system(size: 15, weight: .semibold))
                Text("~/.ssh/config 不存在。\n创建一个配置文件并添加你的服务器。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("创建 ~/.ssh/config") { viewModel.openSSHConfig() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .unreadable:
                Text("SSH 配置不可读").font(.system(size: 15, weight: .semibold))
                Text("无法读取 ~/.ssh/config，请检查文件权限。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".ssh/config")
                    ])
                }
                .buttonStyle(.bordered).controlSize(.small)
            case .empty:
                Text("没有配置服务器").font(.system(size: 15, weight: .semibold))
                Text("~/.ssh/config 中没有任何 Host 条目。\n添加一个服务器后重试。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("编辑 ~/.ssh/config") { viewModel.openSSHConfig() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .loading:
                ProgressView("检测 SSH 配置…").controlSize(.small)
            case .ok:
                EmptyView()
            }
        }
        .padding(24)
        Spacer()
        Button("关闭") { onClose() }.buttonStyle(.bordered).controlSize(.small)
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
            .disabled(viewModel.selectedAlias.isEmpty || viewModel.tracker != nil)
        }
    }
}

@MainActor
final class DestinationPanelController {
    private var panel: NSPanel?
    private let onClose: () -> Void

    init(selections: [URL], onClose: @escaping () -> Void) {
        self.onClose = onClose
        let viewModel = DestinationViewModel(selections: selections)
        let host = NSHostingController(
            rootView: DestinationView(viewModel: viewModel) { [weak self] in
                self?.panel?.close()
            }
        )
        let panel = NSPanel(contentViewController: host)
        panel.title = "传送到服务器"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 360, height: 440))
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel = nil
                self?.onClose()
            }
        }

        viewModel.onClose = { [weak self] in
            self?.panel?.close()
        }
    }

    func show() {
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
