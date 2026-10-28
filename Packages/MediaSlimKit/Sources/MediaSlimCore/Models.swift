import Foundation

/// The two kinds of media the app handles.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo
    case video
}

/// Properties of a library item that decide whether it is safe to re-encode it.
public enum MediaTrait: String, Codable, Sendable, CaseIterable {
    /// A Live Photo: a still plus a paired video that must stay linked.
    case livePhoto
    /// Edited in Photos. Replacing it would flatten the edit history.
    case edited
    /// A RAW or RAW+JPEG capture.
    case raw
    /// Slow-motion or other high-frame-rate video with edit metadata.
    case highFrameRate
    /// Cinematic-mode video with an editable depth track.
    case cinematic
    /// Spatial photo or video for Apple Vision Pro.
    case spatial
    /// Not owned by the user's library (shared album, iTunes sync, and so on).
    case notInUserLibrary
    case screenshot
    case panorama
}

/// One photo or video in the user's library, described without any framework types
/// so that every layer of the app (and every test) can use it.
public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    /// The Photos `localIdentifier`.
    public let id: String
    public let kind: MediaKind
    /// Size of the original file. `nil` when the system does not report it.
    public let byteSize: Int64?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Duration in seconds. Videos only.
    public let duration: TimeInterval?
    public let creationDate: Date?
    /// Uniform type identifier of the original resource, for example `public.heic`.
    public let uniformTypeIdentifier: String?
    public let traits: Set<MediaTrait>

    public init(
        id: String,
        kind: MediaKind,
        byteSize: Int64?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval? = nil,
        creationDate: Date? = nil,
        uniformTypeIdentifier: String? = nil,
        traits: Set<MediaTrait> = []
    ) {
        self.id = id
        self.kind = kind
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.creationDate = creationDate
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.traits = traits
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }
}

/// What happens to the original after its compressed copy is safely in the library.
public enum OriginalHandling: String, Codable, Sendable, CaseIterable {
    /// The original is deleted through the system confirmation dialog.
    /// Photos keeps it in Recently Deleted for 30 days.
    case replace
    /// Both versions stay. The compressed copy goes into the app's album.
    case keepBoth
}

/// Where a scan looks for media.
public enum ScanScope: Hashable, Sendable {
    case entireLibrary
    case album(id: String)
    case items(ids: [String])
}

/// A user album, as shown in the source picker.
public struct AlbumInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let itemCount: Int

    public init(id: String, title: String, itemCount: Int) {
        self.id = id
        self.title = title
        self.itemCount = itemCount
    }
}

/// Photos access level, independent of PhotoKit.
public enum LibraryAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// The user shared only some items. The app works with those.
    case limited
    case full

    public var canRead: Bool { self == .full || self == .limited }
}
