import Foundation

public enum TransferPhase: Equatable, Sendable {
    case preparing
    case sending
    case done
    case failed(String)
}

public enum TransferDirection: String, Sendable { case send, receive }

/// How much we know about the transfer's total size.
/// `.full` and `.totalsOnly` both compute percent from real transferred bytes;
/// the only difference is whether the UI shows "X / Y MB". `.unknown` shows
/// an indeterminate bar.
public enum SizeKnowledge: Sendable {
    case full        // total bytes known (local scan or `find -printf`)
    case totalsOnly  // total bytes known (`du -sk`) but no per-file sizes
    case unknown     // total unknown → indeterminate bar
}

public struct TransferProgress: Equatable, Sendable {
    public let phase: TransferPhase
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalFiles: Int
    public let currentFileIndex: Int
    public let currentFileName: String?
    public let rateBytesPerSec: Int64?
    public let etaSeconds: Int?
    public let sizeKnowledge: SizeKnowledge

    public var percent: Double {
        guard totalBytes > 0 else { return phase == .done ? 1 : 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}

public struct ParsedProgress: Equatable, Sendable {
    public let percent: Double                 // 0...1
    public let transferredBytes: Int64?        // real bytes for the current file
    public let fileName: String?
    public let rateBytesPerSec: Int64?
    public init(percent: Double, transferredBytes: Int64?,
                fileName: String?, rateBytesPerSec: Int64?) {
        self.percent = percent
        self.transferredBytes = transferredBytes
        self.fileName = fileName
        self.rateBytesPerSec = rateBytesPerSec
    }
}

public struct PreparedTransfer: Equatable, Sendable {
    public let totalBytes: Int64
    public let totalFiles: Int
    public let sizeKnowledge: SizeKnowledge
    public init(totalBytes: Int64, totalFiles: Int, sizeKnowledge: SizeKnowledge) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.sizeKnowledge = sizeKnowledge
    }
}

/// Pure state machine that turns scp per-file progress events into a monotonic
/// byte-based total. Accumulates the **real transferred bytes** scp reports on
/// each progress line (the size field after the percent), so the bar is byte-
/// accurate for both send and receive regardless of how the total was obtained.
public struct TransferAggregator {
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let totalFiles: Int
    public let sizeKnowledge: SizeKnowledge

    private var completedBytes: Int64 = 0     // bytes of fully-prior files
    private var currentFileName: String?
    private var currentFileIndex: Int = 0
    private var currentFileBytesSeen: Int64 = 0  // max transferred bytes for the current file
    private var phase: TransferPhase = .preparing
    private var rateBytesPerSec: Int64?
    private var etaSeconds: Int?

    public init(direction: TransferDirection, totalBytes: Int64, totalFiles: Int,
                sizeKnowledge: SizeKnowledge = .full) {
        self.direction = direction
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.sizeKnowledge = sizeKnowledge
    }

    public var progress: TransferProgress {
        let done = min(completedBytes + currentFileBytesSeen, max(totalBytes, 0))
        return TransferProgress(
            phase: phase, direction: direction, totalBytes: totalBytes,
            completedBytes: done, totalFiles: totalFiles,
            currentFileIndex: currentFileIndex, currentFileName: currentFileName,
            rateBytesPerSec: rateBytesPerSec, etaSeconds: etaSeconds,
            sizeKnowledge: sizeKnowledge)
    }

    public mutating func startSending() {
        if case .preparing = phase { phase = .sending }
    }

    public mutating func ingest(_ event: ParsedProgress) {
        if case .preparing = phase { phase = .sending }

        if let name = event.fileName, name != currentFileName {
            // Close out the previous file with its last observed byte count.
            if currentFileName != nil {
                completedBytes += currentFileBytesSeen
            }
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
            currentFileName = name
            currentFileBytesSeen = 0
        } else if currentFileName == nil, let name = event.fileName {
            currentFileName = name
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
        }

        // Real bytes transferred for the current file — scp gives us this
        // directly on every progress line. Take the max to stay monotonic.
        if let transferred = event.transferredBytes, transferred > currentFileBytesSeen {
            currentFileBytesSeen = transferred
        }

        rateBytesPerSec = event.rateBytesPerSec
        if let r = event.rateBytesPerSec, r > 0, totalBytes > 0 {
            let remaining = max(totalBytes - (completedBytes + currentFileBytesSeen), 0)
            etaSeconds = Int(remaining / r)
        }
    }

    public mutating func complete() {
        completedBytes = totalBytes
        currentFileBytesSeen = 0
        phase = .done
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }
}
