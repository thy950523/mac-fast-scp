import AppKit
import SwiftUI
import FastSCPCore

enum SSHConfigSummary: Equatable {
    case checking
    case ok(hostCount: Int)
    case notFound
    case empty
}

@MainActor
final class AboutViewModel: ObservableObject {
    @Published var extensionStatus: ExtensionStatus = .unknown
    @Published var sshConfigStatus: SSHConfigSummary = .checking
    @Published var checking = false

    func refresh() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ext = ExtensionChecker.check()
            let ssh = Self.checkSSHConfig()
            DispatchQueue.main.async {
                self?.extensionStatus = ext
                self?.sshConfigStatus = ssh
                self?.checking = false
            }
        }
    }

    private static func checkSSHConfig() -> SSHConfigSummary {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return .notFound
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .notFound
        }
        let hosts = SSHConfigParser.parse(text)
        if hosts.isEmpty { return .empty }
        return .ok(hostCount: hosts.count)
    }
}

struct AboutView: View {
    @StateObject private var vm = AboutViewModel()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.zhuzhong.FastSCP"
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }

            Text("FastSCP").font(.system(size: 19, weight: .semibold))

            Text("在 Finder 右键里，一键 SCP 到你的服务器。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            extensionStatusSection
            sshConfigSection

            Divider()

            HStack {
                Text("版本").foregroundStyle(.secondary)
                Spacer()
                Text("\(version) (\(build))")
            }.font(.system(size: 11))

            HStack {
                Text("Bundle ID").foregroundStyle(.secondary)
                Spacer()
                Text(bundleID).font(.system(size: 9, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 11))

            Link(destination: URL(string: "https://github.com/thy950523/mac-fast-scp")!) {
                Label("github.com/thy950523/mac-fast-scp", systemImage: "link")
            }.font(.system(size: 10))

            Text("MIT License · © 2026 zhuzhong")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Button("完成") { NSApp.keyWindow?.close() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { vm.refresh() }
    }

    // MARK: - Extension

    @ViewBuilder
    private var extensionStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Finder 扩展").font(.system(size: 11, weight: .medium))
                Spacer()
                if vm.checking {
                    ProgressView().controlSize(.small)
                } else {
                    extBadge
                }
            }

            switch vm.extensionStatus {
            case .loaded:
                Label("已启用，右键菜单可用。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.green)
            case .notLoaded:
                VStack(alignment: .leading, spacing: 4) {
                    Label("未启用。需要在系统设置中开启。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    HStack {
                        Button("打开系统设置 → 扩展") { ExtensionChecker.openSystemSettings() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("重新检测") { vm.refresh() }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                }
            case .unknown:
                VStack(alignment: .leading, spacing: 4) {
                    Label("无法检测扩展状态。", systemImage: "questionmark.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("重新检测") { vm.refresh() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var extBadge: some View {
        switch vm.extensionStatus {
        case .loaded:
            badge("已启用", color: .green)
        case .notLoaded:
            badge("未启用", color: .orange)
        case .unknown:
            badge("未知", color: .secondary)
        }
    }

    // MARK: - SSH Config

    @ViewBuilder
    private var sshConfigSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SSH 配置").font(.system(size: 11, weight: .medium))
                Spacer()
                if case .checking = vm.sshConfigStatus {
                    ProgressView().controlSize(.small)
                } else {
                    sshBadge
                }
            }

            switch vm.sshConfigStatus {
            case .ok(let count):
                Label("检测到 \(count) 台服务器（~/.ssh/config）", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.green)
            case .notFound:
                VStack(alignment: .leading, spacing: 4) {
                    Label("未找到 ~/.ssh/config", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Button("创建 SSH 配置") {
                        let home = FileManager.default.homeDirectoryForCurrentUser
                        let sshDir = home.appendingPathComponent(".ssh", isDirectory: true)
                        let config = sshDir.appendingPathComponent("config")
                        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: config.path) {
                            FileManager.default.createFile(atPath: config.path, contents: nil)
                        }
                        NSWorkspace.shared.open(config)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            case .empty:
                Label("~/.ssh/config 中没有服务器条目", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            case .checking:
                Text("检测中…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sshBadge: some View {
        switch vm.sshConfigStatus {
        case .ok:
            badge("已配置", color: .green)
        case .notFound, .empty:
            badge("未配置", color: .orange)
        case .checking:
            badge("检测中", color: .secondary)
        }
    }

    // MARK: - Shared

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

final class AboutPanelController {
    private var panel: NSPanel?
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    func show() {
        if panel == nil {
            let host = NSHostingController(rootView: AboutView())
            let p = NSPanel(contentViewController: host)
            p.title = "关于 FastSCP"
            p.styleMask = [.titled, .closable]
            p.setContentSize(NSSize(width: 380, height: 540))
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: p,
                queue: .main
            ) { [weak self] _ in
                self?.panel = nil
                self?.onClose?()
            }
            panel = p
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
