import Cocoa
import FinderSync
import FastSCPCore

class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Observe the whole filesystem so the menu appears for any selection.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "FastSCP")
        let recents = RecentStore.shared().load()
        let maxRecent = min(recents.count, FastSCPConfig.maxRecentDestinations)

        if maxRecent == 0 {
            // No history yet: collapse the single entry to the top level.
            let item = NSMenuItem(title: "传送到服务器…",
                                  action: #selector(chooseDestination(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = Self.menuIcon
            menu.addItem(item)
            return menu
        }

        // With history: top-level "传送到服务器 ▸" with submenu.
        let parent = NSMenuItem(title: "传送到服务器",
                                action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "传送到服务器")

        let manual = NSMenuItem(title: "手动选择…",
                                action: #selector(chooseDestination(_:)),
                                keyEquivalent: "")
        manual.target = self
        manual.image = Self.menuIcon
        submenu.addItem(manual)

        if maxRecent > 0 {
            submenu.addItem(.separator())
            // RecentDestinations.add() keeps the array in time-desc order
            // (newest at index 0) and caps at maxRecentDestinations,
            // so the first `maxRecent` entries are exactly what we want.
            for r in recents.prefix(maxRecent) {
                let item = NSMenuItem(title: "\(r.alias):\(r.remotePath)",
                                      action: #selector(quickSend(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.image = Self.recentIcon
                item.representedObject = r
                submenu.addItem(item)
            }
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
