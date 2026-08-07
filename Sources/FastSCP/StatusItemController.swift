import AppKit
import SwiftUI
import FastSCPCore

extension Notification.Name {
    static let fastSCPShowAbout = Notification.Name("fastSCPShowAbout")
    static let fastSCPShowPanel = Notification.Name("fastSCPShowPanel")
    static let fastSCPShowReceivePanel = Notification.Name("fastSCPShowReceivePanel")
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: URLCoordinator

    init(coordinator: URLCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.up",
                                   accessibilityDescription: "FastSCP")
            button.image?.isTemplate = true
        }

        super.init()

        let menu = NSMenu()

        let send = NSMenuItem(title: "传送到服务器…",
                              action: #selector(openFilePicker),
                              keyEquivalent: "n")
        send.target = self
        menu.addItem(send)

        let receive = NSMenuItem(title: "从服务器接收…",
                                 action: #selector(receiveFromServer),
                                 keyEquivalent: "")
        receive.target = self
        menu.addItem(receive)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 FastSCP",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 FastSCP",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要传送到服务器的文件或文件夹"
        panel.prompt = "传送"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            coordinator.panelRequest = URLCoordinator.PanelRequest(selections: panel.urls)
            NotificationCenter.default.post(name: .fastSCPShowPanel, object: nil)
        }
    }

    @objc private func receiveFromServer() {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        coordinator.receiveRequest = URLCoordinator.ReceiveRequest(
            destURL: dest, allowChangeDest: true)
        NotificationCenter.default.post(name: .fastSCPShowReceivePanel, object: nil)
    }

    @objc private func showAbout() {
        NotificationCenter.default.post(name: .fastSCPShowAbout, object: nil)
    }
}
