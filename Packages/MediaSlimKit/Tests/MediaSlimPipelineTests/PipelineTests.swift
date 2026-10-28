import Foundation
import MediaSlimCore
@testable import MediaSlimPipeline
import Testing

struct Harness {
    let dir: URL
    let library: DemoPhotoLibrary
    let journal: JournalStore
    let temp: SecureTempStore
    let coordinator: ProcessingCoordinator

    init(
        items: [MediaItem] = DemoPhotoLibrary.sampleItems(),
        photoRatio: Double = 0.55,
        monitor: any ResourceMonitoring = FixedResourceMonitor(),
        storage: any StorageInspecting = FixedStorageInspector()
    ) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineTests-\(UUID().uuidString)")
        library = DemoPhotoLibrary(assets: items)
        journal = try JournalStore(directory: dir.appendingPathComponent("journal"))
        temp = try SecureTempStore(directory: dir.appendingPathComponent("work"))
        coordinator = ProcessingCoordinator(
            library: library,
            compressor: DemoCompressor(tempStore: temp, photoRatio: photoRatio, delay: .milliseconds(1)),
            journal: journal,
            tempStore: temp,
            monitor: monitor,
            storage: storage
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    func run(_ items: [MediaItem], _ options: ProcessingOptions) async -> [ProcessingEvent] {
        var events: [ProcessingEvent] = []
        for await event in await coordinator.start(items: items, options: options) { events.append(event) }
        return events
    }

    static func eligible(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { EligibilityPolicy().evaluate($0).isEligible }
    }
}

extension [ProcessingEvent] {
    var summary: RunSummary? {
        for case let .finished(summary, _) in self { return summary }
        return nil
    }
}

@Suite("Processing pipeline", .serialized)
struct PipelineTests {
    @Test("Replace: copies saved first, originals deleted only after confirmation")
    func replaceFlow() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let items = Harness.eligible(try await h.library.scan(.entireLibrary))
        #expect(!items.isEmpty)

        let events = await h.run(items, ProcessingOptions(originalHandling: .replace))
        let summary = try #require(events.summary)
        #expect(summary.processed == items.count)
        #expect(summary.bytesSaved > 0)

        // Nothing deleted yet: deletion waits for the user-facing step.
        for item in items { #expect(await h.library.assetExists(id: item.id)) }
        #expect(await h.coordinator.pendingDeletionCount() == items.count)

        let outcome = await h.coordinator.deletePendingOriginals()
        guard case let .deleted(count, freed) = outcome else {
            Issue.record("Expected deletion, got \(outcome)")
            return
        }
        #expect(count == items.count)
        #expect(freed == summary.bytesSaved)
        for item in items { #expect(await !h.library.assetExists(id: item.id)) }
        #expect(await h.coordinator.pendingDeletionCount() == 0)
    }

    @Test("Keep both: nothing is ever deleted")
    func keepBothFlow() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let items = Harness.eligible(try await h.library.scan(.entireLibrary))
        _ = await h.run(items, ProcessingOptions(originalHandling: .keepBoth))
        #expect(await h.coordinator.pendingDeletionCount() == 0)
        #expect(await h.coordinator.deletePendingOriginals() == .nothingPending)
        for item in items { #expect(await h.library.assetExists(id: item.id)) }
        #expect(await h.library.deletedIDs.isEmpty)
    }

    @Test("Declining the system dialog keeps everything and can be retried")
    func declinedDeletion() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let items = Harness.eligible(try await h.library.scan(.entireLibrary))
        _ = await h.run(items, ProcessingOptions(originalHandling: .replace))
        await h.library.setDeclineDeletion(true)
        #expect(await h.coordinator.deletePendingOriginals() == .declined(count: items.count))
        for item in items { #expect(await h.library.assetExists(id: item.id)) }

        await h.coordinator.keepBothForPending()
        #expect(await h.coordinator.pendingDeletionCount() == 0)
    }

    @Test("An original whose copy disappeared is never deleted")
    func missingCopyProtectsOriginal() async throws {
        let h = try Harness(items: [DemoPhotoLibrary.sampleItems()[0]])
        defer { h.cleanUp() }
        let item = DemoPhotoLibrary.sampleItems()[0]
        _ = await h.run([item], ProcessingOptions(originalHandling: .replace))

        let entry = try #require(await h.journal.entry(id: item.id))
        let newID = try #require(entry.newAssetID)
        try await h.library.deleteAssets(ids: [newID]) // the copy vanishes (for example, deleted by the user)

        #expect(await h.coordinator.deletePendingOriginals() == .failed)
        #expect(await h.library.assetExists(id: item.id))
    }

    @Test("A failed export leaves the original untouched and is reported")
    func exportFailure() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let item = DemoPhotoLibrary.sampleItems()[0]
        await h.library.setFailExport([item.id])
        let events = await h.run([item], ProcessingOptions(originalHandling: .replace))
        #expect(events.summary?.failed == 1)
        #expect(await h.coordinator.pendingDeletionCount() == 0)
        #expect(await h.library.assetExists(id: item.id))
    }

    @Test("Too little saving is skipped, not saved")
    func notWorthIt() async throws {
        let h = try Harness(photoRatio: 0.95)
        defer { h.cleanUp() }
        let item = DemoPhotoLibrary.sampleItems()[0]
        let events = await h.run([item], ProcessingOptions(originalHandling: .replace, minimumSavingsFraction: 0.10))
        #expect(events.summary?.skipped == 1)
        #expect(await h.library.assets.count == DemoPhotoLibrary.sampleItems().count)
    }

    @Test("A hot device pauses the run; cancelling leaves originals untouched")
    func thermalPause() async throws {
        let h = try Harness(monitor: FixedResourceMonitor([.thermal]))
        defer { h.cleanUp() }
        await h.coordinator.setPollInterval(.milliseconds(10))
        let item = DemoPhotoLibrary.sampleItems()[0]

        var sawPause = false
        var finishedCancelled = false
        for await event in await h.coordinator.start(items: [item], options: ProcessingOptions()) {
            switch event {
            case let .paused(reasons):
                sawPause = reasons.contains(.thermal)
                await h.coordinator.cancel()
            case let .finished(_, cancelled):
                finishedCancelled = cancelled
            default:
                break
            }
        }
        #expect(sawPause)
        #expect(finishedCancelled)
        #expect(await h.library.assetExists(id: item.id))
        #expect(await h.journal.interrupted().isEmpty)
    }

    @Test("Temporary files are gone after a run")
    func tempCleanup() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let items = Harness.eligible(try await h.library.scan(.entireLibrary))
        _ = await h.run(items, ProcessingOptions(originalHandling: .keepBoth))
        let left = try FileManager.default.contentsOfDirectory(atPath: h.temp.directory.path)
        #expect(left.isEmpty)
    }
}

@Suite("Journal")
struct JournalTests {
    @Test("Survives a restart and ignores a torn last line")
    func persistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("JournalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = UUID()

        do {
            let journal = try JournalStore(directory: dir)
            var entry = JournalEntry(id: "a", kind: .photo, runID: run, originalBytes: 100)
            try await journal.record(entry)
            entry.state = .awaitingDeletion
            entry.newAssetID = "a2"
            entry.newBytes = 40
            try await journal.record(entry)
            try await journal.record(JournalEntry(id: "b", kind: .video, runID: run, originalBytes: 500))
        }
        // Simulate a crash in the middle of writing a line.
        let log = dir.appendingPathComponent("journal.log")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"c\",\"ki".utf8))
        try handle.close()

        let reloaded = try JournalStore(directory: dir)
        let a = try #require(await reloaded.entry(id: "a"))
        #expect(a.state == .awaitingDeletion)
        #expect(a.savedBytes == 60)
        #expect(await reloaded.entry(id: "b")?.state == .queued)
        #expect(await reloaded.entry(id: "c") == nil)
        #expect(await reloaded.pendingDeletion().map(\.id) == ["a"])
    }

    @Test("Compaction drops finished entries of finished runs only")
    func compaction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("JournalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try JournalStore(directory: dir)
        let done = UUID(), open = UUID()
        var finished = RunSummary(id: done, startedAt: Date(), options: ProcessingOptions())
        finished.finishedAt = Date()
        try await journal.saveRun(finished)
        try await journal.saveRun(RunSummary(id: open, startedAt: Date(), options: ProcessingOptions()))
        try await journal.record(JournalEntry(id: "x", kind: .photo, runID: done, originalBytes: 1, state: .completed))
        try await journal.record(JournalEntry(id: "y", kind: .photo, runID: done, originalBytes: 1, state: .awaitingDeletion))
        try await journal.record(JournalEntry(id: "z", kind: .photo, runID: open, originalBytes: 1, state: .completed))
        try await journal.compact()
        #expect(await journal.entry(id: "x") == nil)
        #expect(await journal.entry(id: "y") != nil)
        #expect(await journal.entry(id: "z") != nil)
    }
}
