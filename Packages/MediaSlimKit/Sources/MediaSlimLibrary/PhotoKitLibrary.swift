#if canImport(Photos) && os(iOS)
import CoreLocation
import Foundation
import MediaSlimCore
import os
import Photos
import UIKit
import UniformTypeIdentifiers

/// The real photo library, through PhotoKit.
///
/// Privacy: the app asks for `.readWrite` because replacing a file requires reading the original
/// and deleting it. Limited access is fully supported: only the items the user shared are seen.
/// Nothing read here leaves the device; files go only to the app's protected temporary folder.
public struct PhotoKitLibrary: PhotoLibraryService {
    public static let appAlbumTitle = "MediaSlim"
    private static let log = Logger(subsystem: "com.mediaslim.library", category: "photos")

    public init() {}

    // MARK: - Authorization

    public func authorization() async -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: - Reading

    static func mediaOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// Smart albums for videos and favorites first, then the user's own albums by name.
    public func albums() async -> [AlbumInfo] {
        func infos(_ result: PHFetchResult<PHAssetCollection>) -> [AlbumInfo] {
            var infos: [AlbumInfo] = []
            result.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: Self.mediaOptions()).count
                if count > 0 {
                    infos.append(AlbumInfo(id: collection.localIdentifier, title: collection.localizedTitle ?? "", itemCount: count))
                }
            }
            return infos
        }
        var smart: [AlbumInfo] = []
        for subtype in [PHAssetCollectionSubtype.smartAlbumVideos, .smartAlbumFavorites] {
            smart += infos(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil))
        }
        let user = infos(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return smart + user
    }

    public func scan(_ scope: ScanScope) async throws -> [MediaItem] {
        guard await authorization().canRead else { throw LibraryError.notAuthorized }
        let assets: PHFetchResult<PHAsset>
        switch scope {
        case .entireLibrary:
            assets = PHAsset.fetchAssets(with: Self.mediaOptions())
        case let .album(id):
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw LibraryError.assetNotFound
            }
            assets = PHAsset.fetchAssets(in: collection, options: Self.mediaOptions())
        case let .items(ids):
            assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.mediaOptions())
        }
        var items: [MediaItem] = []
        items.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            if index % 200 == 0 { try Task.checkCancellation() }
            items.append(Self.describe(assets.object(at: index)))
        }
        return items
    }

    static func primaryResource(of asset: PHAsset, resources: [PHAssetResource]) -> PHAssetResource? {
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        return resources.first { $0.type == type }
    }

    static func describe(_ asset: PHAsset) -> MediaItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let kind: MediaKind = asset.mediaType == .video ? .video : .photo
        let primary = primaryResource(of: asset, resources: resources)

        var traits: Set<MediaTrait> = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoLive) { traits.insert(.livePhoto) }
        if subtypes.contains(.photoScreenshot) { traits.insert(.screenshot) }
        if subtypes.contains(.photoPanorama) { traits.insert(.panorama) }
        if subtypes.contains(.videoHighFrameRate) { traits.insert(.highFrameRate) }
        if subtypes.contains(.videoCinematic) { traits.insert(.cinematic) }
        if #available(iOS 18, *), subtypes.contains(.spatialMedia) { traits.insert(.spatial) }
        if asset.sourceType != .typeUserLibrary { traits.insert(.notInUserLibrary) }
        let types = Set(resources.map(\.type))
        if !types.isDisjoint(with: [.adjustmentData, .fullSizePhoto, .fullSizeVideo]) { traits.insert(.edited) }
        if kind == .photo, types.contains(.pairedVideo) { traits.insert(.livePhoto) }
        if types.contains(.alternatePhoto) { traits.insert(.raw) }
        if let uti = primary?.uniformTypeIdentifier, let type = UTType(uti), type.conforms(to: .rawImage) {
            traits.insert(.raw)
        }

        return MediaItem(
            id: asset.localIdentifier,
            kind: kind,
            byteSize: primary.flatMap(fileSize),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: kind == .video ? asset.duration : nil,
            creationDate: asset.creationDate,
            uniformTypeIdentifier: primary?.uniformTypeIdentifier,
            traits: traits
        )
    }

    /// PhotoKit reports the size through key-value coding only. Guarded so a future change
    /// to that key degrades to "size unknown" instead of crashing.
    static func fileSize(_ resource: PHAssetResource) -> Int64? {
        let key = "fileSize"
        guard resource.responds(to: NSSelectorFromString(key)) else { return nil }
        return (resource.value(forKey: key) as? NSNumber)?.int64Value
    }

    public func assetExists(id: String) async -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
    }

    // MARK: - Export

    public func exportOriginal(of item: MediaItem, to url: URL, allowCloudDownload: Bool) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
              let resource = Self.primaryResource(of: asset, resources: PHAssetResource.assetResources(for: asset)) else {
            throw LibraryError.assetNotFound
        }
        try? FileManager.default.removeItem(at: url)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowCloudDownload
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.networkAccessRequired.rawValue {
                        continuation.resume(throwing: LibraryError.needsCloudDownload)
                    } else {
                        Self.log.error("Export failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                        continuation.resume(throwing: LibraryError.exportFailed)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Writing

    public func saveCompressed(file: URL, for item: MediaItem, handling: OriginalHandling) async throws -> String {
        guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            throw LibraryError.assetNotFound
        }
        let originalName = Self.primaryResource(of: original, resources: PHAssetResource.assetResources(for: original))?.originalFilename
        var albumIDs = Self.userAlbumIDs(containing: original)
        if handling == .keepBoth, let appAlbum = try? await Self.appAlbumID() {
            albumIDs.append(appAlbum)
        }

        let kind = item.kind
        let filename = Self.filename(basedOn: originalName, kind: kind, fileExtension: file.pathExtension)
        let creationDate = original.creationDate
        let location = original.location.map(LocationSnapshot.init)
        let isFavorite = original.isFavorite
        let isHidden = original.isHidden
        let targetAlbums = albumIDs
        let createdID = LockedValue<String?>(nil)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                options.originalFilename = filename
                request.addResource(with: kind == .photo ? .photo : .video, fileURL: file, options: options)
                request.creationDate = creationDate
                request.location = location?.location
                request.isFavorite = isFavorite
                request.isHidden = isHidden
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                createdID.set(placeholder.localIdentifier)
                guard !targetAlbums.isEmpty else { return }
                PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: targetAlbums, options: nil)
                    .enumerateObjects { collection, _, _ in
                        guard collection.canPerform(.addContent) else { return }
                        PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
                    }
            }
        } catch {
            Self.log.error("Save failed: \((error as NSError).code, privacy: .public)")
            throw LibraryError.saveFailed
        }
        guard let id = createdID.get() else { throw LibraryError.saveFailed }
        return id
    }

    public func deleteAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
        } catch {
            let ns = error as NSError
            if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.userCancelled.rawValue {
                throw LibraryError.deletionDeclined
            }
            Self.log.error("Delete failed: \(ns.code, privacy: .public)")
            throw LibraryError.deletionFailed
        }
    }

    // MARK: - Helpers

    static func filename(basedOn original: String?, kind: MediaKind, fileExtension: String) -> String {
        let stem = original.map { ($0 as NSString).deletingPathExtension } ?? (kind == .photo ? "Photo" : "Video")
        return "\(stem).\(fileExtension.uppercased())"
    }

    /// Albums the user made that contain the asset, so the copy appears in the same places.
    static func userAlbumIDs(containing asset: PHAsset) -> [String] {
        var ids: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, _ in
                if collection.assetCollectionSubtype == .albumRegular, collection.canPerform(.addContent) {
                    ids.append(collection.localIdentifier)
                }
            }
        return ids
    }

    static func appAlbumID() async throws -> String {
        var existing: String?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == appAlbumTitle {
                    existing = collection.localIdentifier
                    stop.pointee = true
                }
            }
        if let existing { return existing }
        let created = LockedValue<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: appAlbumTitle)
            created.set(request.placeholderForCreatedAssetCollection.localIdentifier)
        }
        guard let id = created.get() else { throw LibraryError.saveFailed }
        return id
    }
}

/// A location as plain values, so it can cross into PhotoKit's change block safely.
struct LocationSnapshot: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let course: Double
    let speed: Double
    let timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        course = location.course
        speed = location.speed
        timestamp = location.timestamp
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

/// Small thread-safe box for values produced inside PhotoKit change blocks.
final class LockedValue<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    func set(_ value: Value) { lock.withLock { $0 = value } }
    func get() -> Value { lock.withLock { $0 } }
}

/// Loads small previews for the UI. Never downloads from iCloud.
public struct ThumbnailLoader: Sendable {
    public init() {}

    public func image(for id: String, side: CGFloat, scale: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let size = CGSize(width: side * scale, height: side * scale)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
#endif
