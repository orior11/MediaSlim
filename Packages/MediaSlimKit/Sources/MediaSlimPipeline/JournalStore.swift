import Foundation
import MediaSlimCore

/// Crash-safe record of every item's progress, plus run history.
///
/// Storage format:
/// - `journal.log`: one JSON object per line, appended on every state change and flushed to disk
///   before the next step runs. The last line for an identifier wins. A torn final line from a
///   crash is ignored on load.
/// - `state.json`: run summaries and the identifiers of assets this app created.
///
/// Both files hold only identifiers, sizes and states, never image data or locations. They are
/// encrypted at rest (`completeUntilFirstUserAuthentication`) and excluded from backup.
public actor JournalStore {
    struct State: Codable {
        var runs: [RunSummary] = []
        var processedAssetIDs: Set<String> = []
    }

    private let directory: URL
    private var entries: [String: JournalEntry] = [:]
    private var state = State()
    private var unsavedChanges = 0

    private var logURL: URL { directory.appendingPathComponent("journal.log") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    public init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.protection)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        self.directory = directory

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
           let loaded = try? decoder.decode(State.self, from: data) {
            state = loaded
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("journal.log")) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) {
                    entries[entry.id] = entry
                }
            }
        }
    }

    /// The default location: Application Support/MediaSlim.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MediaSlim", isDirectory: true)
    }

    static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    // MARK: - Entries

    public func record(_ entry: JournalEntry) throws {
        var entry = entry
        entry.updatedAt = Date()
        entries[entry.id] = entry
        try append(entry)
    }

    public func entry(id: String) -> JournalEntry? { entries[id] }

    public func entries(runID: UUID) -> [JournalEntry] {
        entries.values.filter { $0.runID == runID }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Originals whose compressed copy is verified in the library and that are waiting to be deleted.
    public func pendingDeletion() -> [JournalEntry] {
        entries.values.filter { $0.state == .awaitingDeletion }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Items of runs that stopped before finishing (crash, kill, background expiry).
    public func interrupted() -> [JournalEntry] {
        entries.values.filter { $0.state == .queued || $0.state == .encoding }
    }

    /// Removes queued items of a run the user cancelled. Items already in progress are kept.
    public func discardQueued(runID: UUID) throws {
        let ids = entries.values.filter { $0.runID == runID && $0.state == .queued }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { entries[id] = nil }
        try compact()
    }

    // MARK: - Runs

    public func saveRun(_ summary: RunSummary) throws {
        if let index = state.runs.firstIndex(where: { $0.id == summary.id }) {
            state.runs[index] = summary
        } else {
            state.runs.append(summary)
        }
        try saveState()
    }

    public func runs() -> [RunSummary] {
        state.runs.sorted { $0.startedAt > $1.startedAt }
    }

    public func run(id: UUID) -> RunSummary? {
        state.runs.first { $0.id == id }
    }

    // MARK: - Processed assets

    public func markProcessed(assetID: String) throws {
        state.processedAssetIDs.insert(assetID)
        unsavedChanges += 1
        if unsavedChanges >= 20 { try saveState() }
    }

    public func processedAssetIDs() -> Set<String> { state.processedAssetIDs }

    // MARK: - Maintenance

    /// Drops finished entries of finished runs and rewrites the log.
    public func compact() throws {
        let finishedRuns = Set(state.runs.filter { $0.finishedAt != nil }.map(\.id))
        entries = entries.filter { !($0.value.isFinished && finishedRuns.contains($0.value.runID)) }
        let encoder = Self.encoder
        var data = Data()
        for entry in entries.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try write(data, to: logURL)
        try saveState()
    }

    /// Deletes all history. Used by "Erase app data" in Settings.
    public func eraseAll() throws {
        entries = [:]
        state = State()
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Disk

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func append(_ entry: JournalEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil, attributes: Self.protection)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // Durable before the caller moves on to the next irreversible step.
        try handle.synchronize()
    }

    private func saveState() throws {
        try write(Self.encoder.encode(state), to: stateURL)
        unsavedChanges = 0
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
