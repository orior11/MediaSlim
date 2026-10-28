import MediaSlimCore
import MediaSlimEngine
import MediaSlimLibrary
import MediaSlimPipeline
import Observation
import os
import SwiftUI
import UIKit

enum Route: Hashable {
    case review
    case processing
    case history
    case settings
}

/// What a scan found, ready for the review screen.
struct ScanReport: Equatable {
    var eligible: [MediaItem]
    var skipped: [SkipReason: Int]
    var photoCount: Int
    var videoCount: Int
    var eligibleBytes: Int64
    var estimatedSavingsLow: Int64
    var estimatedSavingsHigh: Int64

    var skippedCount: Int { skipped.values.reduce(0, +) }
}

enum ScanState: Equatable {
    case idle
    case scanning
    case ready(ScanReport)
    case failed(LibraryError)
}

enum DeletionState: Equatable {
    case notNeeded
    case waiting(count: Int)
    case inProgress
    case deleted(count: Int, bytes: Int64)
    case declined(count: Int)
    case failed
}

/// Live state of the current run, observed by the processing and results screens.
@MainActor
@Observable
final class RunProgress {
    let total: Int
    let options: ProcessingOptions
    var completed = 0
    var currentItem: MediaItem?
    var summary: RunSummary?
    var pauseReasons: Set<PauseReason> = []
    var isFinished = false
    var wasCancelled = false
    var failedCount = 0
    var deletion: DeletionState = .notNeeded
    var lowStorageWarning = false

    init(total: Int, options: ProcessingOptions) {
        self.total = total
        self.options = options
    }

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    var bytesSaved: Int64 { summary?.bytesSaved ?? 0 }
    var isPaused: Bool { !pauseReasons.isEmpty }
}

struct InterruptedRun: Equatable {
    let count: Int
    let options: ProcessingOptions
}

/// The app's single source of truth. Views read it; only it talks to the services.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let isDemo: Bool
    private let library: any PhotoLibraryService
    let coordinator: ProcessingCoordinator
    @ObservationIgnored private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.mediaslim.app", category: "model")

    var authorization: LibraryAuthorization = .notDetermined
    var path: [Route] = []
    var scanState: ScanState = .idle
    var albums: [AlbumInfo] = []
    var progress: RunProgress?
    var pendingDeletionCount = 0
    var pendingDeletionBytes: Int64 = 0
    var interrupted: InterruptedRun?
    var history: [RunSummary] = []
    var isAppActive = true

    init(settings: AppSettings, library: any PhotoLibraryService, coordinator: ProcessingCoordinator, isDemo: Bool) {
        self.settings = settings
        self.library = library
        self.coordinator = coordinator
        self.isDemo = isDemo
    }

    // MARK: - Construction

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let demo = arguments.contains("-demo")
        let defaults: UserDefaults = demo ? (UserDefaults(suiteName: "demo") ?? .standard) : .standard
        if arguments.contains("-resetState") {
            defaults.removePersistentDomain(forName: "demo")
        }
        let settings = AppSettings(defaults: defaults)
        if arguments.contains("-skipOnboarding") { settings.hasCompletedOnboarding = true }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("MediaSlimSession-\(UUID().uuidString)", isDirectory: true)
        let base = demo ? scratch : ((try? JournalStore.defaultDirectory()) ?? scratch)

        // Storage can be unavailable right after a reboot, before the first unlock.
        // Fall back to a session-only folder rather than crashing; the journal then lives
        // only until the app quits, and nothing irreversible depends on it until it is written.
        let temp = (try? SecureTempStore(directory: demo ? base.appendingPathComponent("work") : nil))
            ?? (try? SecureTempStore(directory: scratch.appendingPathComponent("work")))
        let journal = (try? JournalStore(directory: base.appendingPathComponent("journal")))
            ?? (try? JournalStore(directory: scratch.appendingPathComponent("journal")))
        guard let temp, let journal else {
            preconditionFailure("No writable storage at all")
        }
        temp.purgeAll() // Nothing from an earlier session is needed; remove any leftovers.

        let library: any PhotoLibraryService
        let compressor: any MediaCompressing
        if demo {
            library = DemoPhotoLibrary()
            compressor = DemoCompressor(tempStore: temp)
        } else {
            library = PhotoKitLibrary()
            compressor = MediaCompressor(tempStore: temp)
        }
        let coordinator = ProcessingCoordinator(library: library, compressor: compressor, journal: journal, tempStore: temp)
        return AppModel(settings: settings, library: library, coordinator: coordinator, isDemo: demo)
    }

    // MARK: - State refresh

    func refresh() async {
        authorization = await library.authorization()
        pendingDeletionCount = await coordinator.pendingDeletionCount()
        pendingDeletionBytes = await coordinator.pendingDeletionBytes()
        if progress == nil || progress?.isFinished == true, let work = await coordinator.interruptedWork() {
            interrupted = InterruptedRun(count: work.ids.count, options: work.options)
        } else {
            interrupted = nil
        }
        history = await coordinator.history()
    }

    func requestAccess() async {
        authorization = await library.requestAuthorization()
    }

    func loadAlbums() async {
        albums = await library.albums()
    }

    // MARK: - Scanning

    func scan(_ scope: ScanScope) async {
        scanState = .scanning
        if path.last != .review { path.append(.review) }
        do {
            let items = try await library.scan(scope)
            let policy = EligibilityPolicy(processedAssetIDs: await coordinator.processedAssetIDs())
            scanState = .ready(Self.report(for: items, policy: policy, settings: settings))
        } catch let error as LibraryError {
            scanState = .failed(error)
        } catch is CancellationError {
            scanState = .idle
        } catch {
            scanState = .failed(.exportFailed)
        }
    }

    static func report(for items: [MediaItem], policy: EligibilityPolicy, settings: AppSettings) -> ScanReport {
        var report = ScanReport(eligible: [], skipped: [:], photoCount: 0, videoCount: 0, eligibleBytes: 0, estimatedSavingsLow: 0, estimatedSavingsHigh: 0)
        for item in items {
            if item.kind == .photo, !settings.includePhotos { continue }
            if item.kind == .video, !settings.includeVideos { continue }
            switch policy.evaluate(item) {
            case let .eligible(estimate):
                report.eligible.append(item)
                if item.kind == .photo { report.photoCount += 1 } else { report.videoCount += 1 }
                let bytes = item.byteSize ?? 0
                report.eligibleBytes += bytes
                report.estimatedSavingsLow += Int64(Double(bytes) * estimate.low)
                report.estimatedSavingsHigh += Int64(Double(bytes) * estimate.high)
            case let .skipped(reason):
                report.skipped[reason, default: 0] += 1
            }
        }
        // Largest files first: the most space is freed early, even if the run is stopped.
        report.eligible.sort { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        return report
    }

    // MARK: - Running

    func startRun(handling: OriginalHandling) {
        guard case let .ready(report) = scanState, !report.eligible.isEmpty else { return }
        settings.lastOriginalHandling = handling
        let options = ProcessingOptions(
            qualityLevel: settings.qualityLevel,
            originalHandling: handling,
            allowCloudDownloads: settings.allowCloudDownloads
        )
        begin(items: report.eligible, options: options)
    }

    func resumeInterrupted() async {
        guard let work = await coordinator.interruptedWork() else { return }
        do {
            let items = try await library.scan(.items(ids: work.ids))
            interrupted = nil
            begin(items: items, options: work.options)
        } catch {
            log.error("Resume failed: \(String(describing: error), privacy: .private)")
        }
    }

    func discardInterrupted() async {
        await coordinator.discardInterruptedWork()
        await refresh()
    }

    private func begin(items: [MediaItem], options: ProcessingOptions) {
        let progress = RunProgress(total: items.count, options: options)
        self.progress = progress
        path = [.processing]
        UIApplication.shared.isIdleTimerDisabled = true
        runTask = Task {
            let stream = await coordinator.start(items: items, options: options)
            for await event in stream {
                apply(event, to: progress)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            await finishRun(progress)
        }
    }

    /// Waits for the current run, if any. Used by background processing.
    func waitForRun() async {
        await runTask?.value
    }

    var isRunning: Bool {
        guard let progress else { return false }
        return !progress.isFinished
    }

    private func apply(_ event: ProcessingEvent, to progress: RunProgress) {
        switch event {
        case .started:
            Announcer.say(String(localized: "Started. Large files go first."))
        case let .itemStarted(_, item):
            progress.currentItem = item
        case let .itemFinished(index, result, summary):
            progress.completed = index + 1
            progress.summary = summary
            if case .failed = result.status { progress.failedCount += 1 }
            Announcer.progressMilestone(completed: progress.completed, total: progress.total, saved: summary.bytesSaved)
        case let .paused(reasons):
            progress.pauseReasons = reasons
            Announcer.say(String(localized: "Paused."))
        case .resumed:
            progress.pauseReasons = []
            Announcer.say(String(localized: "Resumed."))
        case .storageCheckpoint:
            progress.lowStorageWarning = true
        case let .finished(summary, cancelled):
            progress.summary = summary
            progress.isFinished = true
            progress.wasCancelled = cancelled
            progress.currentItem = nil
            progress.pauseReasons = []
        }
    }

    private func finishRun(_ progress: RunProgress) async {
        await refresh()
        if progress.options.originalHandling == .replace, pendingDeletionCount > 0 {
            progress.deletion = .waiting(count: pendingDeletionCount)
            // The system shows its own confirmation; it can only appear while the app is on screen.
            if isAppActive { await deleteOriginals() }
        }
        let saved = progress.summary?.bytesSaved ?? 0
        Announcer.say(String(localized: "Done. Saved \(Formatters.bytes(saved)).", comment: "Spoken when a run ends"))
    }

    func deleteOriginals() async {
        progress?.deletion = .inProgress
        let outcome = await coordinator.deletePendingOriginals()
        let state: DeletionState = switch outcome {
        case .nothingPending: .notNeeded
        case let .deleted(count, bytes): .deleted(count: count, bytes: bytes)
        case let .declined(count): .declined(count: count)
        case .failed: .failed
        }
        progress?.deletion = state
        if case .deleted = state { progress?.lowStorageWarning = false }
        await refresh()
    }

    func keepBothVersions() async {
        await coordinator.keepBothForPending()
        progress?.deletion = .notNeeded
        await refresh()
    }

    func pause() { Task { await coordinator.pause() } }
    func resume() { Task { await coordinator.resume() } }

    func cancelRun() {
        Task { await coordinator.cancel() }
    }

    /// Background time is over: stop, but keep the queue so it continues later.
    func suspendForBackgroundExpiry() async {
        await coordinator.cancel(keepQueue: true)
    }

    func closeResults() {
        progress = nil
        path = []
        scanState = .idle
        Task { await refresh() }
    }

    // MARK: - Privacy

    func eraseAllData() async {
        try? await coordinator.eraseRecords()
        settings.resetAll()
        settings.hasCompletedOnboarding = true
        await refresh()
    }
}

/// VoiceOver announcements, throttled so they inform without flooding.
@MainActor
enum Announcer {
    private static var lastMilestone = -1

    static func say(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// Speaks at every 10% of progress.
    static func progressMilestone(completed: Int, total: Int, saved: Int64) {
        guard total > 0 else { return }
        let milestone = completed * 10 / total
        if completed == 1 { lastMilestone = 0 }
        guard milestone > lastMilestone, milestone < 10 else { return }
        lastMilestone = milestone
        say(String(localized: "\(completed) of \(total) done. \(Formatters.bytes(saved)) saved.", comment: "Spoken progress update"))
    }
}
