import SwiftUI
import FastSCPCore

/// In-panel transfer status view, shared by the send and receive panels.
/// Replaces the old one-line "NN% detail" text with a full progress layout.
struct TransferStatusView: View {
    @ObservedObject var tracker: TransferTracker
    let alias: String
    let path: String
    var onCancel: () -> Void

    private var p: TransferProgress { tracker.progress }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: p.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)

            Text(headline)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if p.sizeKnowledge == .unknown {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: p.percent)
                    .progressViewStyle(.linear)
            }

            if p.sizeKnowledge != .unknown {
                HStack {
                    Text(percentText)
                        .monospacedDigit()
                    Spacer()
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                Text(sizeAndRateText)
                    .monospacedDigit()
                Spacer()
                if let eta = etaText {
                    Text(eta)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Divider()

            HStack {
                if p.totalFiles > 0 {
                    Text("第 \(max(p.currentFileIndex, 1)) / \(p.totalFiles) 个文件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(p.currentFileName ?? "—")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button("取消传输", role: .cancel) { onCancel() }
                .buttonStyle(.bordered)
        }
        .padding(14)
    }

    private var headline: String {
        p.direction == .send
            ? "正在传输到 \(alias):\(path)"
            : "正在接收自 \(alias):\(path)"
    }

    private var percentText: String {
        p.sizeKnowledge == .unknown ? "" : "\(Int(p.percent * 100))%"
    }

    private var sizeAndRateText: String {
        let rate = p.rateBytesPerSec.map { ByteFormat.rate($0) } ?? "—"
        switch p.sizeKnowledge {
        case .full, .totalsOnly:
            return "\(ByteFormat.size(p.completedBytes)) / \(ByteFormat.size(p.totalBytes)) · \(rate)"
        case .unknown:
            return rate
        }
    }

    private var etaText: String? {
        guard let s = p.etaSeconds, s > 0 else { return nil }
        if s >= 3600 { return "剩余 > 1 小时" }
        let m = s / 60, r = s % 60
        return m > 0 ? "剩余 \(m) 分 \(r) 秒" : "剩余 \(r) 秒"
    }
}

/// Phase-switching transfer UI shared by the send and receive panels.
///
/// This switch MUST live in a view that holds the tracker as `@ObservedObject`.
/// When it lived inside `ReceiveView`/`DestinationView` as a plain function of a
/// `let t`, SwiftUI never re-rendered it on `t.progress` changes: the parent
/// observes the view model, not the tracker, so only the parent's `@Published`
/// changes (e.g. setting `tracker = t`) re-evaluated the switch. Result: after
/// cancelling (`t.fail("已取消")` → phase `.failed`) the panel stayed on the
/// in-progress view with a dead cancel button — the user could keep clicking it
/// (logs showed repeated `cancel() process=false`). The live progress bar still
/// moved only because `TransferStatusView` itself `@ObservedObject`s the tracker;
/// leaving the progress *branch* needs the parent to re-render.
///
/// Hoisting the switch into an `@ObservedObject` sub-view makes the phase change
/// re-render at once. Wording follows `tracker.direction`.
struct TransferPhaseView: View {
    @ObservedObject var tracker: TransferTracker
    let alias: String
    let path: String
    let onCancel: () -> Void
    let onClose: () -> Void

    private var p: TransferProgress { tracker.progress }
    private var isReceive: Bool { p.direction == .receive }
    private var cancelledTitle: String { isReceive ? "已取消接收" : "已取消传输" }
    private var failedTitle: String { isReceive ? "接收失败" : "传输失败" }

    var body: some View {
        switch p.phase {
        case .sending, .preparing:
            TransferStatusView(tracker: tracker, alias: alias, path: path, onCancel: onCancel)
        case .failed(let msg):
            let cancelled = msg == "已取消"
            VStack(spacing: 8) {
                Image(systemName: cancelled ? "xmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(cancelled ? Color.secondary : .orange)
                Text(cancelled ? cancelledTitle : failedTitle)
                    .font(.headline)
                if !cancelled {
                    Text(msg)
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                Button("关闭", role: .cancel) { onClose() }
            }
            .padding(.top, 8)
        case .done:
            EmptyView()
        }
    }
}
