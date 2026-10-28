import Foundation

/// One item's progress through a run. Persisted after every state change, so a crash,
/// a kill or a dead battery never leaves the user without at least one copy of a file.
///
/// Order of operations, and the guarantee at each step:
/// 1. `queued`             — nothing touched.
/// 2. `encoding`           — original untouched; a temporary file may exist.
/// 3. `savedNewAsset`      — both versions are in the library.
/// 4. `awaitingDeletion`   — the new asset was verified; the original may be deleted.
/// 5. `completed`          — replace: original deleted; keepBoth: done.
public struct JournalEntry: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case queued
        case encoding
        case savedNewAsset
        case awaitingDeletion
        case completed
        /// The user declined deletion; both versions remain.
        case keptBoth
        case skipped
        case failed
    }

    public let id: String // original asset identifier
    public let kind: MediaKind
    public let runID: UUID
    public var state: State
    public var originalBytes: Int64?
    public var newAssetID: String?
    public var newBytes: Int64?
    public var skipReason: SkipReason?
    public var failureDescription: String?
    public var updatedAt: Date

    public init(id: String, kind: MediaKind, runID: UUID, originalBytes: Int64?, state: State = .queued, updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.runID = runID
        self.state = state
        self.originalBytes = originalBytes
        self.updatedAt = updatedAt
    }

    /// Bytes this item freed (or will free, once its original is deleted).
    public var savedBytes: Int64 {
        guard let originalBytes, let newBytes else { return 0 }
        return max(0, originalBytes - newBytes)
    }

    public var isFinished: Bool {
        switch state {
        case .completed, .keptBoth, .skipped, .failed: true
        default: false
        }
    }
}

/// A finished run, for the history screen.
public struct RunSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public let options: ProcessingOptions
    public var processed: Int
    public var skipped: Int
    public var failed: Int
    public var bytesBefore: Int64
    public var bytesAfter: Int64

    public init(id: UUID, startedAt: Date, options: ProcessingOptions) {
        self.id = id
        self.startedAt = startedAt
        self.options = options
        processed = 0
        skipped = 0
        failed = 0
        bytesBefore = 0
        bytesAfter = 0
    }

    public var bytesSaved: Int64 { max(0, bytesBefore - bytesAfter) }
    public var savedFraction: Double { bytesBefore > 0 ? Double(bytesSaved) / Double(bytesBefore) : 0 }
}
