import AppKit
import SwiftUI
import FastSCPCore

@MainActor
final class ReceiveViewModel: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var selectedAlias: String = ""
    @Published var currentPath: String = "~"
    @Published var entries: [RemoteEntry] = []
    @Published var selectedNames: Set<String> = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var progressText: String?
    @Published var configStatus: SSHConfigStatus = .loading
    @Published var connectionStatus: ConnectionStatus = .idle

    /// 本地目标目录。`var` 以便菜单栏发起时通过「改…」更换。
    @Published var destURL: URL
    let allowChangeDest: Bool
    /// 来自「最近的目标」：打开面板时定位到该机器/路径；nil 则从默认位置开始。
    private let initialAlias: String?
    private let initialPath: String?
    var onClose: (() -> Void)?

    init(destURL: URL, allowChangeDest: Bool, initialAlias: String? = nil, initialPath: String? = nil) {
        self.destURL = destURL
        self.allowChangeDest = allowChangeDest
        self.initialAlias = initialAlias
        self.initialPath = initialPath
    }

    var selectedCount: Int { selectedNames.count }

    // ssh config 读取逻辑与 DestinationViewModel 一致（v1 复制，见 plan follow-up）。
    func loadHosts() async {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir) {
            configStatus = .notFound
            return
        }
        if isDir.boolValue {
            configStatus = .unreadable
            return
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
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
        // 定位：来自「最近的目标」则用其 alias/path，否则默认到上次用过的机器 + ~
        if let initialAlias, parsed.contains(where: { $0.alias == initialAlias }) {
            selectedAlias = initialAlias
        } else {
            selectedAlias = RecentStore.shared().load().first?.alias ?? parsed.first?.alias ?? ""
        }
        currentPath = initialPath ?? "~"
        await refresh()
    }

    func refresh() async {
        guard !selectedAlias.isEmpty else { return }
        loading = true
        errorMessage = nil
        connectionStatus = .checking
        do {
            entries = try await SSHExecutor.shared.listEntries(alias: selectedAlias, path: currentPath)
            // 目录切换后，保留仍存在于当前列表中的选择。
            selectedNames = selectedNames.filter { name in entries.contains { $0.name == name } }
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
        selectedNames = []
        Task { await refresh() }
    }

    func goUp() {
        if currentPath == "~" || currentPath == "/" { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
        selectedNames = []
        Task { await refresh() }
    }

    func resetForServerChange() {
        currentPath = "~"
        connectionStatus = .idle
        selectedNames = []
        Task { await refresh() }
    }

    func toggle(_ entry: RemoteEntry) {
        if selectedNames.contains(entry.name) {
            selectedNames.remove(entry.name)
        } else {
            selectedNames.insert(entry.name)
        }
    }

    func pull() {
        guard !selectedAlias.isEmpty, !selectedNames.isEmpty else { return }
        Task { await performPull() }
    }

    func performPull() async {
        let names = entries.filter { selectedNames.contains($0.name) }.map(\.name)
        progressText = "接收中…"
        defer { progressText = nil }
        do {
            try await SSHExecutor.shared.pull(
                alias: selectedAlias, remotePath: currentPath,
                names: names, localDest: destURL) { [weak self] p in
                    Task { @MainActor in
                        self?.progressText = p.map { "\($0.percent)% \($0.detail)" } ?? "接收中…"
                    }
                }
            Notifier.send(title: "FastSCP", body: "已接收 \(names.count) 项到 \(destURL.path)")
            onClose?()
        } catch {
            errorMessage = SSHErrorMapper.friendlyMessage(for: error)
        }
    }
}

struct ReceiveView: View {
    @ObservedObject var viewModel: ReceiveViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if case .ok = viewModel.configStatus {
                serverPicker
                pathField
                Divider()
                content
                statusBar
                destRow
                if let err = viewModel.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
                Spacer(minLength: 0)
                footer
                if let p = viewModel.progressText {
                    Text(p).font(.caption).monospacedDigit()
                }
            } else {
                configEmptyState
            }
        }
        .padding(12)
        .frame(width: 360, height: 460)
        .task { await viewModel.loadHosts() }
    }

    @ViewBuilder private var serverPicker: some View {
        HStack {
            Text("从哪台").frame(width: 48, alignment: .leading)
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
            TextField("/远端路径", text: $viewModel.currentPath)
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

    @ViewBuilder private var destRow: some View {
        HStack {
            Image(systemName: "arrow.down.to.line").foregroundStyle(.tint)
            Text("接收到 \(viewModel.destURL.path)")
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if viewModel.allowChangeDest {
                Button("改…") { changeDest() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if viewModel.loading {
            ProgressView("读取目录…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: viewModel.selectedNames.contains(entry.name) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(.tint)
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    Text(entry.name).truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if entry.isDirectory { viewModel.enter(entry) } }
                .onTapGesture { viewModel.toggle(entry) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("返回上层") { viewModel.goUp() }
            Spacer()
            Button("取消", role: .cancel) { onClose() }
            Button("接收 \(viewModel.selectedCount) 项 ← \(viewModel.selectedAlias)") {
                viewModel.pull()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedAlias.isEmpty || viewModel.selectedCount == 0 || viewModel.progressText != nil)
        }
    }

    private func changeDest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择接收到的本地目录"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.destURL = url
        }
    }

    @ViewBuilder private var configEmptyState: some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("没有配置服务器").font(.system(size: 15, weight: .semibold))
            Text("~/.ssh/config 中没有任何 Host 条目。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        Spacer()
        Button("关闭") { onClose() }.buttonStyle(.bordered).controlSize(.small)
    }
}

@MainActor
final class ReceivePanelController {
    private var panel: NSPanel?
    private let onClose: () -> Void

    init(destURL: URL, allowChangeDest: Bool, initialAlias: String? = nil, initialPath: String? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let viewModel = ReceiveViewModel(destURL: destURL, allowChangeDest: allowChangeDest, initialAlias: initialAlias, initialPath: initialPath)
        let host = NSHostingController(
            rootView: ReceiveView(viewModel: viewModel) { [weak self] in
                self?.panel?.close()
            }
        )
        let panel = NSPanel(contentViewController: host)
        panel.title = "从服务器接收"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 360, height: 460))
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
