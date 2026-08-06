import AppKit
import SwiftUI
import FastSCPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = URLCoordinator()
    private var panelController: DestinationPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        coordinator.handle(url)
        react()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { coordinator.handle(url) }
        react()
    }

    private func react() {
        if let req = coordinator.panelRequest {
            coordinator.panelRequest = nil
            panelController = DestinationPanelController(selections: req.selections) { [weak self] in
                self?.panelController = nil
            }
            panelController?.show()
        }
        if let quick = coordinator.quickRequest {
            coordinator.quickRequest = nil
            runQuick(quick)
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
                Notifier.send(title: "FastSCP 传输失败", body: error.localizedDescription)
            }
        }
    }
}
