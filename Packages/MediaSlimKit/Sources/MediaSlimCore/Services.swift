import Foundation

/// Result of trying to compress one file.
public enum CompressionOutcome: Sendable, Equatable {
    /// A smaller file that passed the quality check. The caller owns `url` and must delete it.
    case compressed(url: URL, byteSize: Int64, score: Double)
    /// No encoding reached both the quality threshold and the minimum saving.
    case notWorthIt(bestSavingsFraction: Double?)
}

/// Re-encodes a single media file. Implemented by the engine; mocked in tests and demo mode.
public protocol MediaCompressing: Sendable {
    func compress(
        input: URL,
        kind: MediaKind,
        originalByteSize: Int64,
        options: ProcessingOptions
    ) async throws -> CompressionOutcome
}

/// Errors from the photo library layer, in terms the UI can explain.
public enum LibraryError: Error, Equatable, Sendable {
    case notAuthorized
    case assetNotFound
    case needsCloudDownload
    case exportFailed
    case saveFailed
    /// The user tapped "Don't Allow" in the system deletion dialog.
    case deletionDeclined
    case deletionFailed
}

/// Everything the app needs from the photo library, without PhotoKit types.
public protocol PhotoLibraryService: Sendable {
    func authorization() async -> LibraryAuthorization
    func requestAuthorization() async -> LibraryAuthorization
    func albums() async -> [AlbumInfo]
    func scan(_ scope: ScanScope) async throws -> [MediaItem]
    /// Writes the original resource of `item` to `url`.
    func exportOriginal(of item: MediaItem, to url: URL, allowCloudDownload: Bool) async throws
    /// Adds the compressed file as a new asset with the original's date, location, favorite
    /// state and album membership. Returns the new asset's identifier.
    func saveCompressed(file: URL, for item: MediaItem, handling: OriginalHandling) async throws -> String
    func assetExists(id: String) async -> Bool
    /// Deletes the assets through the system confirmation dialog.
    /// Throws `LibraryError.deletionDeclined` if the user declines.
    func deleteAssets(ids: [String]) async throws
}

/// Free space on the device, so the pipeline can avoid filling it up.
public protocol StorageInspecting: Sendable {
    func availableBytes() -> Int64?
}
