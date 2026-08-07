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
            NSApp.setActivationPolicy(.regular)
            receivePanelController = ReceivePanelController(
                destURL: req.destURL, allowChangeDest: req.allowChangeDest) { [weak self] in
                self?.receivePanelController = nil
                NSApp.setActivationPolicy(.accessory)
            }
            receivePanelController?.show()
        }
    }

    private func runQuick(_ req: URLCoordinator.QuickRequest) {
        Task { @MainActor in
            do {
                try await SSHExecutor.shared.transfer(
                    alias: req.alias, path: req.remotePath, sources: req.selections
                ) { _ in }
                RecentStore.shared().record(.init(alias: req.alias, remotePath: req.remotePath, timestamp: Date()))
                Notifier.send(title: "FastSCP", body: "已发送 \(req.selections.count) 项到 \(req.alias):\(req.remotePath)")
            } catch {
                Notifier.send(title: "FastSCP 传输失败", body: SSHErrorMapper.friendlyMessage(for: error))
            }
        }
    }
}
