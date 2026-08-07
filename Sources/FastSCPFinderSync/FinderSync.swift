import Cocoa
import FinderSync
import FastSCPCore

class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Observe the whole filesystem so the menu appears for any selection.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// Tracks the directory the active Finder window is showing — used as the
    /// "current directory" target for 接收 (receive). Updated by Finder Sync as
    /// the user navigates. May be nil before any window is observed; the receive
    /// menu item is then hidden (send still works via selection).
    private var currentDirectory: URL?

    override func beginObservingDirectory(at url: URL) {
        currentDirectory = url
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "FastSCP")
        let parent = NSMenuItem(title: "FastSCP", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "FastSCP")

        let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
        let recents = RecentStore.shared().load()

        // ── 发送段（需选中项；源 = 选中文件/文件夹）──
        var addedSend = false
        if !selection.isEmpty {
            // (a) 发送到服务器… → 弹目标选择面板（原「手动选择目标…」的功能）
            let sendItem = NSMenuItem(title: "发送到服务器…",
                                      action: #selector(chooseDestination(_:)), keyEquivalent: "")
            sendItem.target = self
            sendItem.image = Self.menuIcon
            submenu.addItem(sendItem)
            // (b) 最近的目标：直接显示最近一次发送到的具体目标 → 一键发送
            if let last = recents.first {
                let item = NSMenuItem(title: "\(last.alias):\(last.remotePath)",
                                      action: #selector(quickSend(_:)), keyEquivalent: "")
                item.target = self
                item.image = Self.recentIcon
                item.representedObject = last
                submenu.addItem(item)
            }
            addedSend = true
        }

        // ── 接收段（需当前目录；目标 = 当前 Finder 目录）──
        if let dest = currentDirectory {
            if addedSend { submenu.addItem(.separator()) }
            let recv = NSMenuItem(title: "从服务器接收…",
                                  action: #selector(receive(_:)), keyEquivalent: "")
            recv.target = self
            recv.image = Self.receiveIcon
            recv.representedObject = dest.path
            submenu.addItem(recv)
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

    @objc func quickSend(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? RecentDestination else { return }
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "quick", token: token,
                extra: ["alias": dest.alias, "path": dest.remotePath])
    }

    @objc func chooseDestination(_ sender: NSMenuItem) {
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "choose", token: token, extra: [:])
    }

    @objc func receive(_ sender: NSMenuItem) {
        guard let destPath = sender.representedObject as? String, !destPath.isEmpty else { return }
        // No local sources for receive → empty token; the app ignores the
        // `list` param in the receive branch.
        openURL(action: "receive", token: "", extra: ["dest": destPath])
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
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }
}
