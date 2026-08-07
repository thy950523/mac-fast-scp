import AppKit
import SwiftUI
import FastSCPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = URLCoordinator()
    private var panelController: DestinationPanelController?
    private var receivePanelController: ReceivePanelController?
    private var aboutController: AboutPanelController?
    private var statusItemController: StatusItemController?
    private var didHandleURLEvent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()

        // 每次启动清掉指向其他路径（旧构建 / 已删除副本）的注册：PluginKit 里的
        // 僵尸扩展条目，以及 LaunchServices 里残留的 FastSCP.app 路径。两者都会让
        // 「设置 > 登录项与扩展」出现多行同名 FastSCP。
        // lsregister -dump 很慢，放后台线程，别卡住启动。
        DispatchQueue.global(qos: .utility).async {
            let pruned = ExtensionChecker.pruneStaleRegistrations()
            if !pruned.isEmpty {
                DiagLog.log("[app] startup pruned \(pruned.count) stale registration(s)")
            }
        }

        // Start as menu-bar agent; Dock icon only appears while a window is open.
        NSApp.setActivationPolicy(.accessory)

        statusItemController = StatusItemController(coordinator: coordinator)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPanelFromNotification),
            name: .fastSCPShowPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showAboutFromNotification),
            name: .fastSCPShowAbout,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showReceivePanelFromNotification),
            name: .fastSCPShowReceivePanel,
            object: nil
        )

        // If launched directly (no fastscp:// URL), show the about window.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didHandleURLEvent else { return }
            self.showAbout()
        }
    }

    private func showAbout() {
        NSApp.setActivationPolicy(.regular)
        if aboutController == nil {
            aboutController = AboutPanelController(onClose: { [weak self] in
                self?.aboutController = nil
                NSApp.setActivationPolicy(.accessory)
            })
        }
        aboutController?.show()
    }

    @objc private func showAboutFromNotification() {
        showAbout()
    }

    @objc private func showPanelFromNotification() {
        react()
    }

    @objc private func showReceivePanelFromNotification() {
        react()
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        didHandleURLEvent = true
        coordinator.handle(url)
        react()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if aboutController != nil || panelController != nil {
            return true
        }
        showAbout()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        didHandleURLEvent = true
        for url in urls { coordinator.handle(url) }
        react()
    }

    private func react() {
        if let req = coordinator.panelRequest {
            coordinator.panelRequest = nil
            NSApp.setActivationPolicy(.regular)
            panelController = DestinationPanelController(selections: req.selections) { [weak self] in
                self?.panelController = nil
                NSApp.setActivationPolicy(.accessory)
            }
            panelController?.show()
        }
        if let quick = coordinator.quickRequest {
            coordinator.quickRequest = nil
            runQuick(quick)
        }
        if let req = coordinator.receiveRequest {
            coordinator.receiveRequest = nil
            DiagLog.log("[app] react(): showing receive panel dest=\(req.destURL.path) changeDest=\(req.allowChangeDest)")
            NSApp.setActivationPolicy(.regular)
            receivePanelController = ReceivePanelController(
                destURL: req.destURL, allowChangeDest: req.allowChangeDest,
                initialAlias: req.initialAlias, initialPath: req.initialPath) { [weak self] in
                self?.receivePanelController = nil
                NSApp.setActivationPolicy(.accessory)
            }
            receivePanelController?.show()
        }
    }

    private func runQuick(_ req: URLCoordinator.QuickRequest) {
        Task { @MainActor in
            let tracker = TransferTracker(sendSelections: req.selections)
            let hud = QuickTransferHUDController(tracker: tracker,
                                                 alias: req.alias,
                                                 path: req.remotePath)
            hud.show()
            await tracker.prepare()
            tracker.start()
            do {
                try await SSHExecutor.shared.transfer(
                    alias: req.alias, path: req.remotePath, sources: req.selections
                ) { p in
                    Task { @MainActor in tracker.ingest(p) }
                }
                tracker.complete()
                RecentStore.shared().record(.init(alias: req.alias,
                                                  remotePath: req.remotePath,
                                                  timestamp: Date()))
                // HUD auto-closes ~1.2s after success; no system notification.
            } catch {
                tracker.fail(SSHErrorMapper.friendlyMessage(for: error))
                // HUD stays until the user closes it.
            }
        }
    }
}
