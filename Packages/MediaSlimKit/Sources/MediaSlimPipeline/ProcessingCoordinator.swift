import Foundation
import MediaSlimCore
import os

/// What happened to one item.
public struct ItemResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case compressed(originalBytes: Int64, newBytes: Int64)
        case skipped(SkipReason)
        case failed(String)
    }

    public let item: MediaItem
    public let status: Status

    public init(item: MediaItem, status: Status) {
        self.item = item
        self.status = status
    }
}

public enum ProcessingEvent: Sendable, Equatable {
    case started(runID: UUID, total: Int)
    case itemStarted(index: Int, item: MediaItem)
    case itemFinished(index: Int, result: ItemResult, summary: RunSummary)
    case paused(Set<PauseReason>)
    case resumed
    /// Space is running low: the UI should offer to delete the originals processed so far.
    case storageCheckpoint(pendingDeletions: Int)
    case finished(RunSummary, cancelled: Bool)
}

public enum DeletionOutcome: Sendable, Equatable {
    case nothingPending
    case deleted(count: Int, bytesFreed: Int64)
    /// The user declined in the system dialog. Both versions stay; they can try again later.
    case declined(count: Int)
    case failed
}

/// Runs a batch, one item at a time, in the order: export → compress → verify → save → (delete).
///
/// Safety rules, each enforced in code below:
/// 1. The journal is written to disk before every step that changes the library.
/// 2. An original is never deleted unless its compressed copy exists in the library.
/// 3. Deletion goes through the system dialog, in one batch, and Photos keeps the originals in
///    Recently Deleted for 30 days.
/// 4. Temporary files are removed when each item finishes, whatever the outcome.
public actor ProcessingCoordinator {
    private let library: any PhotoLibraryService
    private let compressor: any MediaCompressing
    private let journal: JournalStore
    private let tempStore: SecureTempStore
    private let monitor: any ResourceMonitoring
    private let storage: any StorageInspecting
    private let log = Logger(subsystem: "com.mediaslim.pipeline", category: "coordinator")

    /// Pause when free space drops below this.
    public var lowStorageThreshold: Int64 = 1_000_000_000
    /// How often to re-check pause conditions.
    public var pollInterval: Duration = .seconds(3)

    private var userPaused = false
    private var runTask: Task<Void, Never>?
    public private(set) var isRunning = false

    public init(
        library: any PhotoLibraryService,
        compressor: any MediaCompressing,
        journal: JournalStore,
        tempStore: SecureTempStore,
        monitor: any ResourceMonitoring = SystemResourceMonitor(),
        storage: any StorageInspecting = SystemStorageInspector()
    ) {
        self.library = library
        self.compressor = compressor
        self.journal = journal
        self.tempStore = tempStore
        self.monitor = monitor
        self.storage = storage
    }

    public func setPollInterval(_ interval: Duration) { pollInterval = interval }
    public func setLowStorageThreshold(_ bytes: Int64) { lowStorageThreshold = bytes }

    // MARK: - Control

    /// Starts a run. Only one run at a time; a second call while running returns an empty stream.
    public func start(items: [MediaItem], options: ProcessingOptions) -> AsyncStream<ProcessingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessingEvent.self, bufferingPolicy: .unbounded)
        guard !isRunning else {
            continuation.finish()
            return stream
        }
        isRunning = true
        userPaused = false
        runTask = Task { [weak self] in
            await self?.process(items: items, options: options, events: continuation)
            continuation.finish()
        }
        return stream
    }

    public func pause() { userPaused = true }
    public func resume() { userPaused = false }

    /// Stops after the current step.
    /// - Parameter keepQueue: keep the items not yet started, so the run can be resumed later
    ///   (used when background time runs out). When `false`, they are dropped.
    public func cancel(keepQueue: Bool = false) {
        keepQueueOnCancel = keepQueue
        runTask?.cancel()
    }

    private var keepQueueOnCancel = false

    // MARK: - Run

    private func process(items: [MediaItem], options: ProcessingOptions, events: AsyncStream<ProcessingEvent>.Continuation) async {
        defer {
            isRunning = false
            runTask = nil
            tempStore.purgeAll()
        }
        let runID = UUID()
        var summary = RunSummary(id: runID, startedAt: Date(), options: options)
        do {
            try await journal.saveRun(summary)
            for item in items {
                try await journal.record(JournalEntry(id: item.id, kind: item.kind, runID: runID, originalBytes: item.byteSize))
            }
        } catch {
            log.error("Journal unavailable: \(error.localizedDescription, privacy: .private)")
            summary.finishedAt = Date()
            events.yield(.finished(summary, cancelled: true))
            return
        }
        events.yield(.started(runID: runID, total: items.count))

        var cancelled = false
        for (index, item) in items.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            if await !waitUntilAllowed(options: options, events: events) { cancelled = true; break }

            events.yield(.itemStarted(index: index, item: item))
            let result = await processItem(item, runID: runID, options: options)
            if case .failed("cancelled") = result.status { cancelled = true; break }

            switch result.status {
            case let .compressed(before, after):
                summary.processed += 1
                summary.bytesBefore += before
                summary.bytesAfter += after
            case .skipped:
                summary.skipped += 1
            case .failed:
                summary.failed += 1
            }
            try? await journal.saveRun(summary)
            events.yield(.itemFinished(index: index, result: result, summary: summary))

            if options.originalHandling == .replace, isStorageLow() {
                let pending = await journal.pendingDeletion().count
                if pending > 0 { events.yield(.storageCheckpoint(pendingDeletions: pending)) }
            }
        }

        if cancelled, !keepQueueOnCancel { try? await journal.discardQueued(runID: runID) }
        keepQueueOnCancel = false
        summary.finishedAt = Date()
        try? await journal.saveRun(summary)
        try? await journal.compact()
        events.yield(.finished(summary, cancelled: cancelled))
    }

    /// Waits while paused, hot, in Low Power Mode or short of space. Returns false if cancelled.
    private func waitUntilAllowed(options: ProcessingOptions, events: AsyncStream<ProcessingEvent>.Continuation) async -> Bool {
        var announced: Set<PauseReason> = []
        while true {
            var reasons = monitor.blockers()
            if userPaused { reasons.insert(.user) }
            if isStorageLow(critical: true) { reasons.insert(.lowStorage) }
            if reasons.isEmpty {
                if !announced.isEmpty { events.yield(.resumed) }
                return true
            }
            if reasons != announced {
                events.yield(.paused(reasons))
                announced = reasons
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
    }

    private func isStorageLow(critical: Bool = false) -> Bool {
        guard let free = storage.availableBytes() else { return false }
        return free < (critical ? lowStorageThreshold / 2 : lowStorageThreshold)
    }

    private func processItem(_ item: MediaItem, runID: UUID, options: ProcessingOptions) async -> ItemResult {
        var entry = JournalEntry(id: item.id, kind: item.kind, runID: runID, originalBytes: item.byteSize, state: .encoding)
        let input = tempStore.makeFileURL(extension: Self.fileExtension(for: item))
        defer { tempStore.remove(input) }

        do {
            try await journal.record(entry)
            try await library.exportOriginal(of: item, to: input, allowCloudDownload: options.allowCloudDownloads)
            try tempStore.protect(input)
            let originalBytes = tempStore.fileSize(input) ?? item.byteSize ?? 0
            entry.originalBytes = originalBytes

            let outcome = try await compressor.compress(input: input, kind: item.kind, originalByteSize: originalBytes, options: options)
            guard case let .compressed(output, newBytes, _) = outcome else {
                entry.state = .skipped
                entry.skipReason = .notEnoughSavings
                try await journal.record(entry)
                return ItemResult(item: item, status: .skipped(.notEnoughSavings))
            }
            defer { tempStore.remove(output) }

            // Rule 2: the copy must be in the library and verified before anything else happens.
            let newID = try await library.saveCompressed(file: output, for: item, handling: options.originalHandling)
            entry.newAssetID = newID
            entry.newBytes = newBytes
            entry.state = .savedNewAsset
            try await journal.record(entry)
            try await journal.markProcessed(assetID: newID)

            guard await library.assetExists(id: newID) else {
                entry.state = .failed
                entry.failureDescription = "copy missing after save"
                try await journal.record(entry)
                return ItemResult(item: item, status: .failed("copy missing"))
            }

            entry.state = options.originalHandling == .replace ? .awaitingDeletion : .completed
            try await journal.record(entry)
            return ItemResult(item: item, status: .compressed(originalBytes: originalBytes, newBytes: newBytes))
        } catch is CancellationError {
            // The original was not touched. Leave the entry queued so the item can be retried.
            entry.state = .queued
            try? await journal.record(entry)
            return ItemResult(item: item, status: .failed("cancelled"))
        } catch LibraryError.needsCloudDownload {
            entry.state = .skipped
            entry.skipReason = .needsCloudDownload
            try? await journal.record(entry)
            return ItemResult(item: item, status: .skipped(.needsCloudDownload))
        } catch {
            log.error("Item failed: \(String(describing: error), privacy: .private)")
            entry.state = .failed
            entry.failureDescription = String(describing: error)
            try? await journal.record(entry)
            return ItemResult(item: item, status: .failed(String(describing: error)))
        }
    }

    static func fileExtension(for item: MediaItem) -> String {
        switch (item.kind, item.uniformTypeIdentifier) {
        case (.video, "public.mpeg-4"): "mp4"
        case (.video, _): "mov"
        case (.photo, "public.jpeg"): "jpg"
        case (.photo, "public.png"): "png"
        case (.photo, _): "heic"
        }
    }

    // MARK: - Deleting originals

    /// Asks the system to delete every original whose verified copy is in the library.
    /// Must be called while the app is in the foreground, because iOS shows a confirmation dialog.
    public func deletePendingOriginals() async -> DeletionOutcome {
        let pending = await journal.pendingDeletion()
        guard !pending.isEmpty else { return .nothingPending }

        var verified: [JournalEntry] = []
        for var entry in pending {
            if let newID = entry.newAssetID, await library.assetExists(id: newID) {
                verified.append(entry)
            } else {
                // Rule 2 again, at the last moment: no copy, no deletion.
                entry.state = .failed
                entry.failureDescription = "copy missing before deletion"
                try? await journal.record(entry)
            }
        }
        guard !verified.isEmpty else { return .failed }

        do {
            try await library.deleteAssets(ids: verified.map(\.id))
        } catch LibraryError.deletionDeclined {
            return .declined(count: verified.count)
        } catch {
            log.error("Deletion failed: \(String(describing: error), privacy: .private)")
            return .failed
        }

        var freed: Int64 = 0
        for var entry in verified {
            entry.state = .completed
            freed += entry.savedBytes
            try? await journal.record(entry)
        }
        try? await journal.compact()
        return .deleted(count: verified.count, bytesFreed: freed)
    }

    /// The user chose to keep both versions of items waiting for deletion.
    public func keepBothForPending() async {
        for var entry in await journal.pendingDeletion() {
            entry.state = .keptBoth
            try? await journal.record(entry)
        }
        try? await journal.compact()
    }

    /// Items left unfinished by a run that was interrupted, with that run's options.
    public func interruptedWork() async -> (ids: [String], options: ProcessingOptions)? {
        let entries = await journal.interrupted()
        guard let runID = entries.first?.runID, let run = await journal.run(id: runID) else { return nil }
        let ids = entries.filter { $0.runID == runID }.map(\.id)
        return ids.isEmpty ? nil : (ids, run.options)
    }

    /// Forgets an interrupted run without touching any file.
    public func discardInterruptedWork() async {
        for entry in await journal.interrupted() {
            try? await journal.discardQueued(runID: entry.runID)
        }
        for var entry in await journal.interrupted() {
            entry.state = .failed
            entry.failureDescription = "interrupted"
            try? await journal.record(entry)
        }
    }

    public func processedAssetIDs() async -> Set<String> {
        await journal.processedAssetIDs()
    }

    /// Erases the journal and history. Files in the library are not touched.
    public func eraseRecords() async throws {
        try await journal.eraseAll()
        tempStore.purgeAll()
    }

    public func history() async -> [RunSummary] {
        await journal.runs().filter { $0.finishedAt != nil && ($0.processed + $0.skipped + $0.failed) > 0 }
    }

    public func pendingDeletionCount() async -> Int {
        await journal.pendingDeletion().count
    }

    public func pendingDeletionBytes() async -> Int64 {
        await journal.pendingDeletion().reduce(0) { $0 + $1.savedBytes }
    }
}
