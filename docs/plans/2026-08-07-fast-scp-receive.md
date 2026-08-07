# FastSCP 接收(Receive)功能 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在已有「发送」基础上新增「从服务器接收(拉取)」：从 Finder 右键或菜单栏发起，选择机器 + 远端文件/目录，确认后 `scp -r` 拉到当前目录。

**Architecture:** 与发送对称。Finder 右键提供「本地侧」(当前目录=目标)，面板负责「远端侧」(多选源)。新增 `ReceiveViewModel/View/Controller` 镜像发送三件套；`SSHExecutor` 增 `pull`；拉取参数构造抽到 `FastSCPCore` 的纯函数 `SCPCommandBuilder` 便于单测。接收**不做**最近来源列表。

**Tech Stack:** Swift 6 / SwiftUI + AppKit / Finder Sync / xcodegen / XCTest。shell out 到系统 `scp -r`。

**参考设计:** `docs/plans/2026-08-06-fast-scp-receive-design.md`

---

## 前置约定

- **分支**：开始前确认不在 `main` 上（当前在 `main`）。先开特性分支：`git checkout -b feat/receive`。所有提交在此分支。
- **所有 commit message 末尾追加**：
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- **新增 `.swift` 文件后必须先** `xcodegen generate`（project.yml 用目录 glob，新文件不会被自动纳入）。
- **构建命令**：
  - 全量构建(含扩展+core)：`xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`
  - 单测：`xcodebuild -project FastSCP.xcodeproj -scheme FastSCPCoreTests -configuration Debug test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`
- **TDD 范围**：只有 `FastSCPCore` 的纯逻辑可单测（`SCPCommandBuilder`）。`SSHExecutor`/UI/Finder 集成用 `Process`/AppKit，按现有策略手测。
- **YAGNI**：接收面板的「ssh config 空状态」「loadHosts 逻辑」与发送面板有重复，**v1 复制不抽取**（避免改动可工作的发送代码）；列为文末 follow-up。

---

## Task 1: Core 纯函数 `SCPCommandBuilder.pullArgs`（TDD）

拉取参数构造是唯一可单测的核心逻辑，先 TDD。

**Files:**
- Create: `Sources/FastSCPCore/SCPCommandBuilder.swift`
- Test: `Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift`

**Step 1: 写失败测试**

`Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift`:
```swift
import XCTest
@testable import FastSCPCore

final class SCPCommandBuilderTests: XCTestCase {
    func testPullArgsBasic() {
        let dest = URL(fileURLWithPath: "/Users/x/work")
        let args = SCPCommandBuilder.pullArgs(
            alias: "server1", remotePath: "/var/log",
            names: ["access.log", "app"], localDest: dest)
        XCTAssertEqual(args, ["-r", "server1:/var/log/access.log", "server1:/var/log/app", "/Users/x/work/"])
    }

    func testPullArgsStripsTrailingSlashOnRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/var/log/", names: ["a"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:/var/log/a", "/d/"])
    }

    func testPullArgsHandlesTildeRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~", names: ["x"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:~/x", "/d/"])
    }

    func testPullArgsPreservesSpacesInNames() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["my file.txt"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:/p/my file.txt", "/d/"])
    }
}
```

**Step 2: 跑测试确认失败**

`xcodegen generate && xcodebuild -project FastSCP.xcodeproj -scheme FastSCPCoreTests -configuration Debug test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>&1 | tail -5`
Expected: 编译失败，`cannot find 'SCPCommandBuilder' in scope`。

**Step 3: 最小实现**

`Sources/FastSCPCore/SCPCommandBuilder.swift`:
```swift
import Foundation

/// 构造 `scp` 的 argv。纯函数，便于单测。
/// 远端操作数形如 `<alias>:<remotePath>/<name>`；scp 以 argv 传递（非 shell），
/// 故文件名中的空格无需转义。
public enum SCPCommandBuilder {
    /// `scp -r <alias>:<remotePath>/<name> ... <localDest>/`
    /// - Parameters:
    ///   - alias: ssh config 别名
    ///   - remotePath: 远端目录（可带或不带尾斜杠、可为 `~`）
    ///   - names: 要拉取的条目名（文件或目录）
    ///   - localDest: 本地目标目录（需已存在）
    public static func pullArgs(alias: String, remotePath: String,
                                names: [String], localDest: URL) -> [String] {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        var args = ["-r"]
        for name in names {
            args.append("\(alias):\(base)/\(name)")
        }
        args.append(localDest.path + "/")
        return args
    }
}
```

**Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: `Executed N tests, with 0 failures` / `** TEST SUCCEEDED **`。

**Step 5: Commit**
```bash
git add Sources/FastSCPCore/SCPCommandBuilder.swift Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift
git commit -m "feat(core): add SCPCommandBuilder for scp pull argv construction"
```

---

## Task 2: `SSHExecutor` 增 `listEntries` + `pull`

**Files:**
- Modify: `Sources/FastSCP/SSHExecutor.swift`

**Step 1: 加 `listEntries`（不过滤文件）**

在 `SSHExecutor` 中、`listDirectory` 下方新增：
```swift
/// `ssh <alias> ls -ap <path>` → 目录+文件（不过滤）。接收面板用它多选。
func listEntries(alias: String, path: String) async throws -> [RemoteEntry] {
    let result = try await run(exec: "/usr/bin/ssh", args: [alias, "ls", "-ap", path])
    return LsParser.parse(result.stdout)
}
```

**Step 2: 加 `pull`**

在 `transfer` 下方新增：
```swift
/// `scp -r <alias>:<remotePath>/<name> ... <localDest>/`；参数由 `SCPCommandBuilder` 构造。
func pull(alias: String, remotePath: String, names: [String],
          localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
    let args = SCPCommandBuilder.pullArgs(
        alias: alias, remotePath: remotePath, names: names, localDest: localDest)
    try await runWithProgress(exec: "/usr/bin/scp", args: args, progress: progress)
}
```

**Step 3: 构建确认编译**

`xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

**Step 4: Commit**
```bash
git add Sources/FastSCP/SSHExecutor.swift
git commit -m "feat: add SSHExecutor.pull and listEntries"
```

---

## Task 3: `URLCoordinator` 增 `receiveRequest`

**Files:**
- Modify: `Sources/FastSCP/URLCoordinator.swift`

**Step 1: 加 request 类型与 published 属性**

在 `QuickRequest` 结构体下方新增：
```swift
/// Set when the user picked "从服务器接收…" — drives the receive panel.
struct ReceiveRequest: Identifiable, Equatable {
    let id = UUID()
    let destURL: URL
    let allowChangeDest: Bool   // Finder 右键发起=false(只读当前目录); 菜单栏=true
}
```

在 `quickRequest` 属性下方新增：
```swift
@Published var receiveRequest: ReceiveRequest?
```

**Step 2: handle(_:) 增 `case "receive"`**

在 `switch action` 中、`case "quick":` 之后新增：
```swift
case "receive":
    let destPath = comps?.queryItems?.first(where: { $00.name == "dest" })?.value ?? ""
    guard !destPath.isEmpty else { return }
    receiveRequest = ReceiveRequest(
        destURL: URL(fileURLWithPath: destPath),
        allowChangeDest: false)
```

> 说明：经 URL 进来的都是 Finder 右键发起 → `allowChangeDest = false`（只读当前目录）。菜单栏发起不经过 URL，直接在 StatusItemController 里构造 `allowChangeDest = true`。

**Step 3: 构建确认**
`xcodebuild ... -scheme FastSCP build ...`。Expected: `** BUILD SUCCEEDED **`。

**Step 4: Commit**
```bash
git add Sources/FastSCP/URLCoordinator.swift
git commit -m "feat: handle fastscp://receive in URLCoordinator"
```

---

## Task 4: 接收面板 `ReceiveViewModel/View/Controller`

镜像 `DestinationPanel.swift`，差异：列表显示文件+目录并多选；底部「接收 N 项 → <dest>」；可选「改…」换本地目标。

**Files:**
- Create: `Sources/FastSCP/ReceivePanel.swift`

**Step 1: 写 `ReceiveViewModel`**

`Sources/FastSCP/ReceivePanel.swift`（整文件）：
```swift
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

    let destURL: URL
    let allowChangeDest: Bool
    var onClose: (() -> Void)?

    init(destURL: URL, allowChangeDest: Bool) {
        self.destURL = destURL
        self.allowChangeDest = allowChangeDest
    }

    var selectedCount: Int { selectedNames.count }

    // ssh config 读取逻辑与 DestinationViewModel 一致（v1 复制，见 follow-up）。
    func loadHosts() async {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir) {
            configStatus = .notFound; return
        }
        if isDir.boolValue { configStatus = .unreadable; return }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            configStatus = .unreadable; return
        }
        let parsed = SSHConfigParser.parse(text)
        if parsed.isEmpty { configStatus = .empty; return }
        hosts = parsed
        configStatus = .ok(hostCount: parsed.count)
        selectedAlias = RecentStore.shared().load().first?.alias ?? parsed.first?.alias ?? ""
        await refresh()
    }

    func refresh() async {
        guard !selectedAlias.isEmpty else { return }
        loading = true; errorMessage = nil; connectionStatus = .checking
        do {
            entries = try await SSHExecutor.shared.listEntries(alias: selectedAlias, path: currentPath)
            selectedNames = selectedNames.filter { name in entries.contains { $0.name == name } }
            connectionStatus = .ok
        } catch {
            let friendly = SSHErrorMapper.friendlyMessage(for: error)
            connectionStatus = .failed(message: friendly); errorMessage = friendly; entries = []
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
        currentPath = "~"; connectionStatus = .idle; selectedNames = []
        Task { await refresh() }
    }
    func toggle(_ entry: RemoteEntry) {
        if selectedNames.contains(entry.name) { selectedNames.remove(entry.name) }
        else { selectedNames.insert(entry.name) }
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
            .onChange(of: viewModel.selectedAlias) { _, _ in viewModel.resetForServerChange() }
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
            case .idle: EmptyView()
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
            Text("接收到 \(viewModel.destURL.path)").font(.caption).lineLimit(1).truncationMode(.middle)
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
                        .foregroundStyle(entry.isDirectory ? .tint : .secondary)
                    Text(entry.name).truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { viewModel.toggle(entry) }
                .onTapGesture(count: 2) { if entry.isDirectory { viewModel.enter(entry) } }
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
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canChooseDirectories = true
        panel.message = "选择接收到的本地目录"
        // 直接替换 destURL：destURL 是 let，需改为 var（见下 Step 2 调整）
    }

    @ViewBuilder private var configEmptyState: some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("没有配置服务器").font(.system(size: 15, weight: .semibold))
            Text("~/.ssh/config 中没有任何 Host 条目。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        Spacer()
        Button("关闭") { onClose() }.buttonStyle(.bordered).controlSize(.small)
    }
}
```

> **注意 `changeDest()`**：`destURL` 是 `let`，要支持「改…」需把它改成 `@Published var destURL: URL`，并在 `init` 赋值。菜单栏发起(allowChangeDest=true)时才用得到。**Step 2 落地时把 `let destURL` 改为 `@Published var destURL`，并在 `changeDest()` 里 `if panel.runModal() == .OK { viewModel.destURL = panel.url! }`。**（上面代码里 destRow/onChange 已按 var 写好，仅 init 和声明需对齐。）

**Step 2: 写 `ReceivePanelController`**（同文件底部，镜像 DestinationPanelController）
```swift
@MainActor
final class ReceivePanelController {
    private var panel: NSPanel?
    private let onClose: () -> Void

    init(destURL: URL, allowChangeDest: Bool, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let viewModel = ReceiveViewModel(destURL: destURL, allowChangeDest: allowChangeDest)
        let host = NSHostingController(
            rootView: ReceiveView(viewModel: viewModel) { [weak self] in self?.panel?.close() })
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
            forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel = nil; self?.onClose() }
        }
        viewModel.onClose = { [weak self] in self?.panel?.close() }
    }

    func show() {
        panel?.center(); panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

> `SSHConfigStatus` / `ConnectionStatus` 已在 `DestinationPanel.swift` 定义，本 target 内全局可见，无需重复定义。

**Step 3: `xcodegen generate && xcodebuild -scheme FastSCP build`** → Expected `** BUILD SUCCEEDED **`。

**Step 4: Commit**
```bash
git add Sources/FastSCP/ReceivePanel.swift
git commit -m "feat: add receive panel (ReceiveViewModel/View/Controller)"
```

---

## Task 5: 接线 `AppDelegate` + `StatusItemController`

**Files:**
- Modify: `Sources/FastSCP/AppDelegate.swift`
- Modify: `Sources/FastSCP/StatusItemController.swift`

**Step 1: AppDelegate 增接收面板属性与 react 分支**

`AppDelegate`：
- 加属性 `private var receivePanelController: ReceivePanelController?`
- `applicationDidFinishLaunching` 里注册通知观察者：
```swift
NotificationCenter.default.addObserver(
    self, selector: #selector(showReceivePanelFromNotification),
    name: .fastSCPShowReceivePanel, object: nil)
```
- 加方法：
```swift
@objc private func showReceivePanelFromNotification() { react() }
```
- `react()` 末尾追加（在 quick 分支之后）：
```swift
if let req = coordinator.receiveRequest {
    coordinator.receiveRequest = nil
    NSApp.setActivationPolicy(.regular)
    receivePanelController = ReceivePanelController(
        destURL: req.destURL, allowChangeDest: req.allowChangeDest) { [weak self] in
        self?.receivePanelController = nil
        NSApp.setActivationPolicy(.accessory)
    }
    receivePanelController?.show()
}
```

**Step 2: 通知名**

`StatusItemController.swift` 顶部 `Notification.Name` 扩展里加：
```swift
static let fastSCPShowReceivePanel = Notification.Name("fastSCPShowReceivePanel")
```

**Step 3: StatusItemController 加菜单项与动作**

在 `init` 的菜单构建里，「传送到服务器…」与分隔符之间或其下方加：
```swift
let receive = NSMenuItem(title: "从服务器接收…",
                          action: #selector(receiveFromServer), keyEquivalent: "")
receive.target = self
menu.addItem(receive)
menu.addItem(.separator())   // 已有分隔符注意不要重复
```
（放在现有 `send` 之后、`menu.addItem(.separator())` 之前。）

加动作：
```swift
@objc private func receiveFromServer() {
    let dest = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
    coordinator.receiveRequest = URLCoordinator.ReceiveRequest(
        destURL: dest, allowChangeDest: true)
    NotificationCenter.default.post(name: .fastSCPShowReceivePanel, object: nil)
}
```

**Step 4: 构建** `xcodebuild -scheme FastSCP build` → Expected `** BUILD SUCCEEDED **`。

**Step 5: Commit**
```bash
git add Sources/FastSCP/AppDelegate.swift Sources/FastSCP/StatusItemController.swift
git commit -m "feat: wire receive panel into AppDelegate and menu bar"
```

---

## Task 6: FinderSync — 接收入口 + 当前目录跟踪 + 菜单重构

**Files:**
- Modify: `Sources/FastSCPFinderSync/FinderSync.swift`

**关键风险**：Finder Sync 取「当前窗口目录」无干净文档化 API；标准做法是覆盖 `beginObservingDirectory(at:)` 跟踪。这是「接收到当前目录」的核心依赖，**Task 7 必须手测验证**；若不可靠，回退方案：把 `ReceiveRequest.allowChangeDest` 一律设 true（面板里「改…」兜底）。

**Step 1: 加当前目录跟踪 + receive 图标**

`FinderSync` 类内加：
```swift
private var currentDirectory: URL?

override func beginObservingDirectory(at url: URL) {
    currentDirectory = url
}
```
图标区加：
```swift
private static var receiveIcon: NSImage? { makeSymbol(name: "tray.and.arrow.down", pointSize: 14) }
```

**Step 2: 重写 `menu(for:)`**（发送段 + 接收段）
```swift
override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    let menu = NSMenu(title: "FastSCP")
    let parent = NSMenuItem(title: "FastSCP", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "FastSCP")

    let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
    let recents = RecentStore.shared().load()
    let maxRecent = min(recents.count, FastSCPConfig.maxRecentDestinations)

    // ── 发送段（需选中项）──
    var addedSend = false
    if !selection.isEmpty {
        if let last = recents.first {
            let item = NSMenuItem(title: "发送到 \(last.alias):\(last.remotePath)",
                                  action: #selector(quickSend(_:)), keyEquivalent: "")
            item.target = self; item.image = Self.menuIcon
            item.representedObject = last
            submenu.addItem(item)
        }
        if maxRecent > 0 {
            let recentParent = NSMenuItem(title: "最近目标", action: nil, keyEquivalent: "")
            let recentSub = NSMenu(title: "最近目标")
            for r in recents.prefix(maxRecent) {
                let item = NSMenuItem(title: "\(r.alias):\(r.remotePath)",
                                      action: #selector(quickSend(_:)), keyEquivalent: "")
                item.target = self; item.image = Self.recentIcon
                item.representedObject = r
                recentSub.addItem(item)
            }
            recentParent.submenu = recentSub; recentParent.image = Self.recentIcon
            submenu.addItem(recentParent)
        }
        let manual = NSMenuItem(title: "手动选择目标…",
                                action: #selector(chooseDestination(_:)), keyEquivalent: "")
        manual.target = self; manual.image = Self.menuIcon
        submenu.addItem(manual)
        addedSend = true
    }

    // ── 接收段（需当前目录）──
    if let dest = currentDirectory {
        if addedSend { submenu.addItem(.separator()) }
        let recv = NSMenuItem(title: "从服务器接收…",
                              action: #selector(receive(_:)), keyEquivalent: "")
        recv.target = self; recv.image = Self.receiveIcon
        recv.representedObject = dest.path
        submenu.addItem(recv)
    }

    // 兜底
    if submenu.items.isEmpty {
        let off = NSMenuItem(title: "FastSCP 不可用", action: nil, keyEquivalent: "")
        off.isEnabled = false
        submenu.addItem(off)
    }

    parent.submenu = submenu; parent.image = Self.menuIcon
    menu.addItem(parent)
    return menu
}
```

**Step 3: 加 receive 动作**
```swift
@objc func receive(_ sender: NSMenuItem) {
    guard let destPath = sender.representedObject as? String, !destPath.isEmpty else { return }
    openURL(action: "receive", token: "", extra: ["dest": destPath])
}
```
> `openURL` 会附带一个空的 `list` 参数，主 App 的 receive 分支忽略它，无害。

**Step 4: 构建** `xcodebuild -scheme FastSCP build` → Expected `** BUILD SUCCEEDED **`。

**Step 5: Commit**
```bash
git add Sources/FastSCPFinderSync/FinderSync.swift
git commit -m "feat: add receive entry to Finder menu with current-dir tracking"
```

---

## Task 7: 全量构建 + 手动验证（Finder 集成不可自动化）

**Step 1: 全量构建**
```bash
xcodegen generate
xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`。

**Step 2: 单测回归**
```bash
xcodebuild -project FastSCP.xcodeproj -scheme FastSCPCoreTests -configuration Debug test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>&1 | tail -5
```
Expected: 原 18 + 新 4 = 22 tests pass。

**Step 3: 安装并手测**（需一台真实 SSH 服务器）
```bash
DERIVED=$(xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -showBuildSettings CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')
cp -R "$DERIVED/FastSCP.app" /Applications/
```
然后在 系统设置 → 隐私与安全性 → 扩展 → Finder 扩展 里勾选 FastSCP，重启 Finder（`killall Finder`）。

**手测清单**（逐项打勾）：
- [ ] 右键选中文件 → `FastSCP ▸` 出现「发送」段；点「从服务器接收…」**不出现**（无当前目录语义时仍出现，因为背景也有目录）—— 确认接收项在选中文件时也可见。
- [ ] 右键窗口空白处 → `FastSCP ▸ 从服务器接收…` 可见。
- [ ] 点「从服务器接收…」→ 弹接收面板，机器下拉正确。
- [ ] 浏览远端目录：**文件和目录都显示**；双击目录进入；`..`/返回上层工作。
- [ ] 勾选 1 文件 + 1 目录 → 点「接收 2 项」→ 落到**当前 Finder 目录**，名字保留，进度条原地显示，完成出通知。
- [ ] 菜单栏「从服务器接收…」→ 面板默认 `~/Downloads`，有「改…」可换目录。
- [ ] 认证失败/远端路径不存在 → 面板内联红字提示，不崩溃。
- [ ] **关键**：确认 `beginObservingDirectory` 取到的当前目录 == 你右键时所在窗口目录。若不符 → 回退：`URLCoordinator` 的 receive 分支与 StatusItemController 都设 `allowChangeDest = true`，靠「改…」兜底。

**Step 4: 若手测通过，收尾提交**（如有手测中发现的小修）
```bash
git add -A
git commit -m "fix: manual-test touch-ups for receive flow"
```

---

## Follow-up（非本计划范围，记录待办）

- 抽取 `SSHConfigLoader`（纯函数读 ssh config）+ 共享 `ConfigEmptyState` 视图，消除 `DestinationViewModel` 与 `ReceiveViewModel` 的重复。
- 抽取共享「远端目录浏览器」子视图（发送=导航语义 / 接收=多选语义）。
- 接收的「最近来源」若将来要加，扩展 `RecentStore` 存 `{alias, remotePath, localFolder}`。
- 同名文件冲突确认（v1 scp 直接覆盖）。

## 已知限制

- 接收无零弹窗快路径（每次须选源）。
- 多选仅限当前目录内（跨目录多选超出 argv 构造前提，YAGNI）。
- `beginObservingDirectory` 取当前目录依赖 Task 7 手测确认。
