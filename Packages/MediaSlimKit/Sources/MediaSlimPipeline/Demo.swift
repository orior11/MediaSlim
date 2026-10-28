import Foundation
import MediaSlimCore

/// An in-memory photo library for UI tests, previews and the App Store review demo mode.
/// It never touches the real library.
public actor DemoPhotoLibrary: PhotoLibraryService {
    public private(set) var assets: [String: MediaItem]
    public private(set) var deletedIDs: [String] = []
    public var declineDeletion = false
    public var failExportIDs: Set<String> = []
    private var nextID = 1

    public init(assets: [MediaItem] = DemoPhotoLibrary.sampleItems()) {
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    }

    public func setDeclineDeletion(_ value: Bool) { declineDeletion = value }
    public func setFailExport(_ ids: Set<String>) { failExportIDs = ids }

    public func authorization() async -> LibraryAuthorization { .full }
    public func requestAuthorization() async -> LibraryAuthorization { .full }

    public func albums() async -> [AlbumInfo] {
        [
            AlbumInfo(id: "demo-album-trip", title: "Trip", itemCount: 6),
            AlbumInfo(id: "demo-album-family", title: "Family", itemCount: 4),
        ]
    }

    public func scan(_ scope: ScanScope) async throws -> [MediaItem] {
        switch scope {
        case .entireLibrary, .album:
            return assets.values.sorted { $0.id < $1.id }
        case let .items(ids):
            return ids.compactMap { assets[$0] }
        }
    }

    public func exportOriginal(of item: MediaItem, to url: URL, allowCloudDownload: Bool) async throws {
        guard assets[item.id] != nil else { throw LibraryError.assetNotFound }
        if failExportIDs.contains(item.id) { throw LibraryError.exportFailed }
        // A placeholder file of the reported size, so byte accounting matches.
        let size = Int(min(item.byteSize ?? 1_000, 4_000_000))
        try Data(count: size).write(to: url)
    }

    public func saveCompressed(file: URL, for item: MediaItem, handling: OriginalHandling) async throws -> String {
        let id = "demo-new-\(nextID)"
        nextID += 1
        let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        assets[id] = MediaItem(
            id: id, kind: item.kind, byteSize: bytes, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
            duration: item.duration, creationDate: item.creationDate, uniformTypeIdentifier: item.uniformTypeIdentifier
        )
        return id
    }

    public func assetExists(id: String) async -> Bool { assets[id] != nil }

    public func deleteAssets(ids: [String]) async throws {
        if declineDeletion { throw LibraryError.deletionDeclined }
        for id in ids { assets[id] = nil }
        deletedIDs += ids
    }

    /// A believable mix based on the research files: camera photos and videos, a messaging-app
    /// video, a Live Photo and an edited photo.
    public static func sampleItems() -> [MediaItem] {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var items: [MediaItem] = []
        for i in 0..<8 {
            items.append(MediaItem(
                id: "demo-photo-\(i)", kind: .photo, byteSize: Int64(1_900_000 + i * 180_000),
                pixelWidth: 4284, pixelHeight: 5712, creationDate: base.addingTimeInterval(Double(i) * day),
                uniformTypeIdentifier: "public.heic"
            ))
        }
        let videos: [(Int64, Double, Int, Int)] = [
            (16_500_000, 15, 1920, 1080), (21_800_000, 15, 1920, 1080), (9_400_000, 7, 1920, 1080),
        ]
        for (i, v) in videos.enumerated() {
            items.append(MediaItem(
                id: "demo-video-\(i)", kind: .video, byteSize: v.0, pixelWidth: v.2, pixelHeight: v.3,
                duration: v.1, creationDate: base.addingTimeInterval(Double(i) * day),
                uniformTypeIdentifier: "com.apple.quicktime-movie"
            ))
        }
        items.append(MediaItem(
            id: "demo-video-whatsapp", kind: .video, byteSize: 4_070_448, pixelWidth: 1024, pixelHeight: 576,
            duration: 31.1, uniformTypeIdentifier: "public.mpeg-4"
        ))
        items.append(MediaItem(
            id: "demo-photo-live", kind: .photo, byteSize: 2_600_000, pixelWidth: 4284, pixelHeight: 5712,
            uniformTypeIdentifier: "public.heic", traits: [.livePhoto]
        ))
        items.append(MediaItem(
            id: "demo-photo-edited", kind: .photo, byteSize: 2_900_000, pixelWidth: 4284, pixelHeight: 5712,
            uniformTypeIdentifier: "public.heic", traits: [.edited]
        ))
        return items
    }
}

/// A compressor that pretends to work: fixed savings per kind, a short delay, a real temp file.
public struct DemoCompressor: MediaCompressing {
    let tempStore: SecureTempStore
    let photoRatio: Double
    let videoRatio: Double
    let delay: Duration

    public init(tempStore: SecureTempStore, photoRatio: Double = 0.55, videoRatio: Double = 0.30, delay: Duration = .milliseconds(250)) {
        self.tempStore = tempStore
        self.photoRatio = photoRatio
        self.videoRatio = videoRatio
        self.delay = delay
    }

    public func compress(input: URL, kind: MediaKind, originalByteSize: Int64, options: ProcessingOptions) async throws -> CompressionOutcome {
        try await Task.sleep(for: delay)
        let ratio = kind == .photo ? photoRatio : videoRatio
        let bytes = Int64(Double(originalByteSize) * ratio)
        guard 1 - ratio >= options.minimumSavingsFraction else { return .notWorthIt(bestSavingsFraction: 1 - ratio) }
        let url = tempStore.makeFileURL(extension: kind == .photo ? "heic" : "mov")
        try tempStore.write(Data(count: Int(min(bytes, 2_000_000))), to: url)
        return .compressed(url: url, byteSize: bytes, score: kind == .photo ? 0.985 : 0.978)
    }
}

/// A monitor with fixed answers, for tests.
public struct FixedResourceMonitor: ResourceMonitoring {
    let reasons: Set<PauseReason>
    public init(_ reasons: Set<PauseReason> = []) { self.reasons = reasons }
    public func blockers() -> Set<PauseReason> { reasons }
}

public struct FixedStorageInspector: StorageInspecting {
    let bytes: Int64?
    public init(_ bytes: Int64? = 50_000_000_000) { self.bytes = bytes }
    public func availableBytes() -> Int64? { bytes }
}
