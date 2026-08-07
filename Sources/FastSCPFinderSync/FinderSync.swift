import Cocoa
import FinderSync
import FastSCPCore

class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Observe the whole filesystem so the menu appears for any selection.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// 最近一次被 Finder Sync 通知观察到的目录。仅作为 `targetedURL()` 的兜底：
    /// 扩展刚被加载时 `beginObservingDirectory` 可能还没回调过。
    private var currentDirectory: URL?

    override func beginObservingDirectory(at url: URL) {
        currentDirectory = url
    }

    /// 接收的本地目标目录 = 右键发生的那个目录。
    ///
    /// 早先只用 `currentDirectory`，但它依赖 `beginObservingDirectory` 先被回调；
    /// 扩展刚重装/重启时该值为 nil，导致整个「从服务器接收」段直接消失。
    /// `targetedURL()` 由 Finder 在构建菜单时提供，才是权威来源：
    ///   - 在窗口空白处右键 → 当前目录本身
    ///   - 选中某项右键 → 该项；若是文件夹用它自己，否则用其父目录
    private func receiveDestination() -> URL? {
        guard let target = FIFinderSyncController.default().targetedURL() else {
            return currentDirectory
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
           isDir.boolValue {
            return target
        }
        return target.deletingLastPathComponent()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "FastSCP")
        let parent = NSMenuItem(title: "FastSCP", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "FastSCP")

        let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
        // 发送与接收各自独立的「最近服务器」列表（每台服务器一条，最多 3 条）。
        let sendRecents = RecentStore.shared().load()
        let receiveRecents = RecentStore.sharedReceive().load()

        // ── 发送段（需选中项；源 = 选中文件/文件夹）──
        var addedSend = false
        if !selection.isEmpty {
            // (a) 发送到服务器… → 弹目标选择面板（原「手动选择目标…」的功能）
            let sendItem = NSMenuItem(title: "发送到服务器…",
                                      action: #selector(chooseDestination(_:)), keyEquivalent: "")
            sendItem.target = self
            sendItem.image = Self.menuIcon
            submenu.addItem(sendItem)
            // (b) 最近发送到的服务器（最多 3 台，最近的在最前）→ 一键发送
            for (index, dest) in sendRecents.enumerated() {
                let item = NSMenuItem(title: "\(dest.alias):\(dest.remotePath)",
                                      action: #selector(quickSendRecent(_:)), keyEquivalent: "")
                item.target = self
                item.image = Self.recentIcon
                item.tag = index
                submenu.addItem(item)
            }
            addedSend = true
        }

        // ── 接收段（目标 = 右键所在目录）──
        if receiveDestination() != nil {
            if addedSend { submenu.addItem(.separator()) }
            // (a) 从服务器接收… → 打开接收面板（从默认位置开始）
            let recv = NSMenuItem(title: "从服务器接收…",
                                  action: #selector(receive(_:)), keyEquivalent: "")
            recv.target = self
            recv.image = Self.receiveIcon
            recv.tag = -1
            submenu.addItem(recv)
            // (b) 最近接收过的服务器（最多 3 台）→ 打开面板并定位到该机器+路径
            for (index, dest) in receiveRecents.enumerated() {
                let item = NSMenuItem(title: "\(dest.alias):\(dest.remotePath)",
                                      action: #selector(receive(_:)), keyEquivalent: "")
                item.target = self
                item.image = Self.recentIcon
                item.tag = index
                submenu.addItem(item)
            }
        }

        // 兜底：既无选中也无当前目录（极少见）
        if submenu.items.isEmpty {
            let off = NSMenuItem(title: "FastSCP 不可用", action: nil, keyEquivalent: "")
            off.isEnabled = false
            submenu.addItem(off)
        }

        parent.submenu = submenu
        parent.image = Self.menuIcon
        menu.addItem(parent)
        return menu
    }

    // MARK: - icons (SF Symbols rendered with explicit theme color)
    //
    // SF Symbols' template/hierarchical rendering can be unreliable for theme
    // adaptation when used inside a Finder Sync extension. So instead of relying
    // on `isTemplate`, we resolve the appropriate color ourselves (system
    // `labelColor` ≈ black on light, ≈ white on dark) and bake it into the
    // symbol image at menu-build time. The menu is rebuilt on every right-click
    // (`menu(for:)` is invoked fresh), so theme changes are picked up
    // automatically without any observer.

    private static func makeSymbol(name: String, pointSize: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(cfg) else { return nil }
        return tinted(symbol, color: NSColor.labelColor)
    }

    // Built fresh on every menu(for:) invocation, so theme changes are picked up.
    private static var menuIcon: NSImage? { makeSymbol(name: "tray.and.arrow.up", pointSize: 14) }
    private static var recentIcon: NSImage? { makeSymbol(name: "clock", pointSize: 12) }
    private static var receiveIcon: NSImage? { makeSymbol(name: "tray.and.arrow.down", pointSize: 14) }

    /// Render `symbol` into a fresh image whose opaque pixels are `color`.
    /// Preserves the symbol's silhouette (alpha mask).
    private static func tinted(_ symbol: NSImage, color: NSColor) -> NSImage {
        let size = symbol.size
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        // First fill with our color (so the image plane starts with the right color).
        color.setFill()
        rect.fill()
        // Then draw the symbol on top using `.destinationIn`, which keeps
        // the color plane but uses the symbol's alpha as the mask.
        symbol.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)
        return out
    }

    @objc func quickSendRecent(_ sender: NSMenuItem) {
        // 不依赖 representedObject（跨 Finder XPC 边界会丢失桥接）；点击时按 tag 重新读取。
        let recents = RecentStore.shared().load()
        guard sender.tag >= 0, sender.tag < recents.count else { return }
        let dest = recents[sender.tag]
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "quick", token: token,
                extra: ["alias": dest.alias, "path": dest.remotePath])
    }

    @objc func chooseDestination(_ sender: NSMenuItem) {
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "choose", token: token, extra: [:])
    }

    @objc func receive(_ sender: NSMenuItem) {
        // dest 在点击时重新解析（不通过 representedObject 传递，见上）。
        guard let dest = receiveDestination() else {
            DiagLog.log("[ext] receive: no destination directory at click time")
            return
        }
        var extra: [String: String] = ["dest": dest.path]
        // tag >= 0：来自「最近的服务器」，附带 alias/path 让主 App 定位到该远端位置。
        let recents = RecentStore.sharedReceive().load()
        if sender.tag >= 0, sender.tag < recents.count {
            extra["alias"] = recents[sender.tag].alias
            extra["path"] = recents[sender.tag].remotePath
        }
        DiagLog.log("[ext] receive click: tag=\(sender.tag) dest=\(dest.path) extra=\(extra)")
        // No local sources for receive → empty token; the app ignores `list`.
        openURL(action: "receive", token: "", extra: extra)
    }

    // MARK: - handoff helpers

    private func writeSelectionBatch() -> String? {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }
        let token = UUID().uuidString
        let fileURL = SharedPaths.batchURL(token: token)
        let text = urls.map(\.path).joined(separator: "\n")
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        return token
    }

    private func openURL(action: String, token: String, extra: [String: String]) {
        var comps = URLComponents()
        comps.scheme = FastSCPConfig.urlScheme
        comps.host = action
        var items = [URLQueryItem(name: "list", value: token)]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else {
            DiagLog.log("[ext] openURL: FAILED to build URL for action=\(action)")
            return
        }
        let opened = NSWorkspace.shared.open(url)
        DiagLog.log("[ext] openURL action=\(action) url=\(url.absoluteString) NSWorkspace.open.returned=\(opened)")
    }
}
