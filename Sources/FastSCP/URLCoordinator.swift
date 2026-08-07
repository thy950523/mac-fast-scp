import Foundation
import SwiftUI
import FastSCPCore

@MainActor
final class URLCoordinator: ObservableObject {
    /// Set when the user picked "传送到服务器…" — drives the destination panel.
    @Published var panelRequest: PanelRequest?
    /// Set when the user picked a quick/recent target — drives a headless transfer.
    @Published var quickRequest: QuickRequest?
    /// Set when the user picked "从服务器接收…" — drives the receive panel.
    @Published var receiveRequest: ReceiveRequest?

    struct PanelRequest: Identifiable, Equatable {
        let id = UUID()
        let selections: [URL]
    }

    struct QuickRequest: Identifiable, Equatable {
        let id = UUID()
        let selections: [URL]
        let alias: String
        let remotePath: String
    }

    struct ReceiveRequest: Identifiable, Equatable {
        let id = UUID()
        let destURL: URL
        /// Finder 右键发起=false(只读当前目录)；菜单栏发起=true(可「改…」)。
        let allowChangeDest: Bool
    }

    func handle(_ url: URL) {
        guard url.scheme == FastSCPConfig.urlScheme else { return }
        let action = url.host ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let token = comps?.queryItems?.first(where: { $0.name == "list" })?.value ?? ""

        switch action {
        case "choose":
            panelRequest = PanelRequest(selections: SelectionStore.read(token: token))
        case "quick":
            let alias = comps?.queryItems?.first(where: { $0.name == "alias" })?.value ?? ""
            let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
            guard !alias.isEmpty else { return }
            quickRequest = QuickRequest(
                selections: SelectionStore.read(token: token),
                alias: alias,
                remotePath: path
            )
        case "receive":
            let destPath = comps?.queryItems?.first(where: { $0.name == "dest" })?.value ?? ""
            guard !destPath.isEmpty else { return }
            receiveRequest = ReceiveRequest(
                destURL: URL(fileURLWithPath: destPath),
                allowChangeDest: false)
        default:
            break
        }
    }
}
