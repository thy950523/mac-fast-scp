import Foundation

public enum TransferPhase: Equatable, Sendable {
    case preparing
    case sending
    case done
    case failed(String)
}

public enum TransferDirection: String, Sendable { case send, receive }

/// How much we know about the transfer's total size; drives which progress
/// fields the UI can show.
public enum SizeKnowledge: Sendable {
    case full        // total bytes + per-file sizes → smooth byte-level progress
    case totalsOnly  // total bytes + file count only → ratio by file count
    case unknown     // nothing → indeterminate bar + current file name
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
    public let percent: Double          // 0...1
    public let fileName: String?
    public let rateBytesPerSec: Int64?
    public init(percent: Double, fileName: String?, rateBytesPerSec: Int64?) {
        self.percent = percent
        self.fileName = fileName
        self.rateBytesPerSec = rateBytesPerSec
    }
}

public struct PreparedTransfer: Equatable, Sendable {
    public let totalBytes: Int64
    public let totalFiles: Int
    public let lookup: [String: Int64]
    public let sizeKnowledge: SizeKnowledge
    public init(totalBytes: Int64, totalFiles: Int, lookup: [String: Int64], sizeKnowledge: SizeKnowledge) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.lookup = lookup
        self.sizeKnowledge = sizeKnowledge
    }
}

/// Pure state machine that turns per-file scp progress events into a monotonic
/// total. No UI or concurrency dependencies — fully unit-testable.
public struct TransferAggregator {
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let totalFiles: Int
    public let sizeKnowledge: SizeKnowledge

    private var fileSizeLookup: [String: Int64]
    private var completedBytes: Int64 = 0
    private var completedFiles: Int = 0
    private var currentFileName: String?
    private var currentFileIndex: Int = 0
    private var currentFileSize: Int64 = 0
    private var currentFileBytesSeen: Int64 = 0
    private var currentFileMaxPct: Double = 0
    private var phase: TransferPhase = .preparing
    private var rateBytesPerSec: Int64?
    private var etaSeconds: Int?

    public init(direction: TransferDirection, totalBytes: Int64, totalFiles: Int,
                fileSizeLookup: [String: Int64] = [:], sizeKnowledge: SizeKnowledge = .full) {
        self.direction = direction
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.fileSizeLookup = fileSizeLookup
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
        let pct = min(max(event.percent, 0), 1)

        if let name = event.fileName, name != currentFileName {
            // Credit the previous file only if there was one (the first
            // transition has nothing to close out yet).
            if currentFileName != nil {
                switch sizeKnowledge {
                case .full:
                    completedBytes += currentFileSize
                case .totalsOnly:
                    completedFiles += 1
                    if totalFiles > 0 {
                        completedBytes = totalBytes * Int64(completedFiles) / Int64(totalFiles)
                    }
                case .unknown:
                    break
                }
            }
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
            currentFileName = name
            // Prefer the per-file size from the lookup; if unknown, assume this
            // file accounts for all remaining bytes (correct for a single file
            // with no lookup, and a sensible best-effort otherwise).
            currentFileSize = fileSizeLookup[name]
                ?? max(totalBytes - completedBytes, 0)
            currentFileBytesSeen = 0
            currentFileMaxPct = 0
        } else if currentFileName == nil, let name = event.fileName {
            currentFileName = name
            currentFileSize = fileSizeLookup[name]
                ?? max(totalBytes - completedBytes, 0)
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
        }

        switch sizeKnowledge {
        case .full:
            if pct >= currentFileMaxPct {
                currentFileMaxPct = pct
                currentFileBytesSeen = Int64(Double(currentFileSize) * pct)
            }
        case .totalsOnly:
            if pct >= currentFileMaxPct { currentFileMaxPct = pct }
            if totalFiles > 0 {
                let ratio = min(max(
                    Double(completedFiles) / Double(totalFiles)
                        + pct / Double(totalFiles), 0), 1)
                currentFileBytesSeen = Int64(Double(totalBytes) * ratio) - completedBytes
            }
        case .unknown:
            currentFileBytesSeen = 0
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
