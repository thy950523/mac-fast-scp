import AppKit
import SwiftUI
import FastSCPCore

/// A top-right floating panel that tracks a quick-send transfer in place of a
/// system notification (UNUserNotificationCenter can't update progress live).
/// Auto-fades ~1.2s after success; on failure it stays until the user closes it.
/// Single-instance: there is only one quick-send at a time.
@MainActor
final class QuickTransferHUDController {
    /// Live HUDs keep themselves alive (the caller's Task may finish before the
    /// auto-fade completes). Released in `dismiss()`.
    private static var active: [ObjectIdentifier: QuickTransferHUDController] = [:]

    private var window: NSPanel?
    private let tracker: TransferTracker
    private let alias: String
    private let path: String

    init(tracker: TransferTracker, alias: String, path: String) {
        self.tracker = tracker
        self.alias = alias
        self.path = path
    }

    func show() {
        let host = NSHostingController(rootView: HUDView(tracker: tracker, alias: alias, path: path) { [weak self] in
            self?.dismiss()
        })

        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setContentSize(NSSize(width: 320, height: 120))

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: v.maxX - s.width - 16,
                                        y: v.maxY - s.height - 16))
        }

        self.window = panel
        Self.active[ObjectIdentifier(self)] = self
        panel.orderFrontRegardless()
        observe()
    }

    private func observe() {
        Task { @MainActor [weak self] in
            while let self, self.window != nil {
                switch self.tracker.progress.phase {
                case .done:
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.fadeOut()
                    return
                case .failed:
                    return   // stay until the user closes
                default:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func fadeOut() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
        Self.active.removeValue(forKey: ObjectIdentifier(self))
    }
}

private struct HUDView: View {
    @ObservedObject var tracker: TransferTracker
    let alias: String
    let path: String
    var onClose: () -> Void

    private var p: TransferProgress { tracker.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch p.phase {
            case .preparing:
                row(icon: "arrow.up.circle", title: "准备中 \(alias):\(path)")
                ProgressView().progressViewStyle(.linear)
                Text("正在统计文件…").font(.caption2).foregroundStyle(.secondary)
            case .sending:
                row(icon: "arrow.up.circle",
                    title: "正在传输 \(alias):\(path)",
                    trailing: p.sizeKnowledge == .unknown ? nil : "\(Int(p.percent * 100))%")
                if p.sizeKnowledge == .unknown {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: p.percent).progressViewStyle(.linear)
                }
                HStack(spacing: 6) {
                    if p.sizeKnowledge == .full {
                        Text("\(ByteFormat.size(p.completedBytes)) / \(ByteFormat.size(p.totalBytes))")
                            .font(.caption2).monospacedDigit()
                    } else {
                        Text("传输中").font(.caption2)
                    }
                    if let r = p.rateBytesPerSec {
                        Text("· \(ByteFormat.rate(r))").font(.caption2).monospacedDigit()
                    }
                    Spacer()
                }
                if p.totalFiles > 0 {
                    Text("第 \(max(p.currentFileIndex, 1)) / \(p.totalFiles) 个 · \(p.currentFileName ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            case .done:
                row(icon: "checkmark.circle.fill", color: .green,
                    title: "已发送到 \(alias):\(path)")
            case .failed(let msg):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("传输失败").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                HStack { Spacer(); Button("关闭") { onClose() }.controlSize(.small) }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func row(icon: String, color: Color = .accentColor, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if let t = trailing {
                Text(t).font(.caption).monospacedDigit()
            }
        }
    }
}
