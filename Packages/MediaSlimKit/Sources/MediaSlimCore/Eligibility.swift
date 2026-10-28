import Foundation

/// Why an item is left untouched.
public enum SkipReason: String, Codable, Sendable, CaseIterable {
    case livePhoto
    case edited
    case raw
    case slowMotion
    case cinematic
    case spatial
    case notInUserLibrary
    case unsupportedFormat
    case tooSmall
    /// The file is already compressed hard (for example, received through a messaging app).
    /// Re-encoding it would make it larger or visibly worse.
    case alreadyCompressed
    /// The app produced this file in an earlier run.
    case alreadyProcessed
    /// The original is only in iCloud and downloads are turned off.
    case needsCloudDownload
    /// Re-encoding did not reach the minimum saving at the chosen quality.
    case notEnoughSavings
}

/// Expected saving as a fraction of the original size, for planning and display only.
/// The engine always measures the real result before anything is replaced.
public struct SavingsEstimate: Sendable, Equatable, Codable {
    public let low: Double
    public let high: Double

    public init(low: Double, high: Double) {
        precondition(low <= high, "low must not exceed high")
        self.low = max(0, min(1, low))
        self.high = max(0, min(1, high))
    }

    public var midpoint: Double { (low + high) / 2 }
}

public enum Eligibility: Sendable, Equatable {
    case eligible(SavingsEstimate)
    case skipped(SkipReason)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

/// Decides, before any decoding, which items are safe and worth processing.
///
/// The rules are deliberately conservative: anything whose structure could break when
/// replaced (Live Photos, edits, RAW, slow motion, cinematic, spatial) is skipped in v1.
public struct EligibilityPolicy: Sendable {
    /// Files smaller than this are not worth the work.
    public var minimumBytes: Int64
    /// Video bits per pixel per frame below which a file counts as already compressed.
    /// Research: messaging-app video measured about 0.06, iPhone camera video about 0.17.
    public var minimumVideoBitsPerPixel: Double
    /// Photo bits per pixel below which a file counts as already compressed.
    public var minimumPhotoBitsPerPixel: Double
    /// Identifiers of assets this app created earlier.
    public var processedAssetIDs: Set<String>

    public init(
        minimumBytes: Int64 = 150_000,
        minimumVideoBitsPerPixel: Double = 0.08,
        minimumPhotoBitsPerPixel: Double = 0.30,
        processedAssetIDs: Set<String> = []
    ) {
        self.minimumBytes = minimumBytes
        self.minimumVideoBitsPerPixel = minimumVideoBitsPerPixel
        self.minimumPhotoBitsPerPixel = minimumPhotoBitsPerPixel
        self.processedAssetIDs = processedAssetIDs
    }

    /// Frame rate assumed when the real rate is unknown at scan time.
    static let assumedFrameRate = 30.0

    static let supportedPhotoTypes: Set<String> = [
        "public.heic", "public.heif", "public.jpeg", "public.png",
    ]
    static let supportedVideoTypes: Set<String> = [
        "com.apple.quicktime-movie", "public.mpeg-4", "public.movie",
    ]

    public func evaluate(_ item: MediaItem) -> Eligibility {
        if processedAssetIDs.contains(item.id) { return .skipped(.alreadyProcessed) }
        if let reason = structuralSkipReason(for: item) { return .skipped(reason) }

        if let type = item.uniformTypeIdentifier {
            let supported = item.kind == .photo ? Self.supportedPhotoTypes : Self.supportedVideoTypes
            if !supported.contains(type) { return .skipped(.unsupportedFormat) }
        }

        guard let bytes = item.byteSize else {
            // Size unknown: let the engine measure it.
            return .eligible(defaultEstimate(for: item))
        }
        if bytes < minimumBytes { return .skipped(.tooSmall) }

        switch item.kind {
        case .photo:
            guard item.pixelCount > 0 else { return .eligible(defaultEstimate(for: item)) }
            let bpp = Double(bytes * 8) / Double(item.pixelCount)
            if bpp < minimumPhotoBitsPerPixel { return .skipped(.alreadyCompressed) }
            return .eligible(photoEstimate(type: item.uniformTypeIdentifier, bitsPerPixel: bpp))
        case .video:
            guard let bpp = Self.videoBitsPerPixel(item) else {
                return .eligible(defaultEstimate(for: item))
            }
            if bpp < minimumVideoBitsPerPixel { return .skipped(.alreadyCompressed) }
            return .eligible(Self.videoEstimate(bitsPerPixel: bpp))
        }
    }

    private func structuralSkipReason(for item: MediaItem) -> SkipReason? {
        let t = item.traits
        if t.contains(.notInUserLibrary) { return .notInUserLibrary }
        if t.contains(.edited) { return .edited }
        if t.contains(.livePhoto) { return .livePhoto }
        if t.contains(.raw) { return .raw }
        if t.contains(.highFrameRate) { return .slowMotion }
        if t.contains(.cinematic) { return .cinematic }
        if t.contains(.spatial) { return .spatial }
        return nil
    }

    /// Bits per pixel per frame, from file size and duration.
    public static func videoBitsPerPixel(_ item: MediaItem, frameRate: Double = assumedFrameRate) -> Double? {
        guard let bytes = item.byteSize, let duration = item.duration, duration > 0, item.pixelCount > 0 else {
            return nil
        }
        return Double(bytes * 8) / (Double(item.pixelCount) * frameRate * duration)
    }

    // Ranges below are taken from the research experiment (4 photos, 7 videos).

    private func photoEstimate(type: String?, bitsPerPixel: Double) -> SavingsEstimate {
        switch type {
        case "public.png": SavingsEstimate(low: 0.60, high: 0.85)
        case "public.jpeg": SavingsEstimate(low: 0.30, high: 0.55)
        default: bitsPerPixel > 0.9 ? SavingsEstimate(low: 0.38, high: 0.50) : SavingsEstimate(low: 0.20, high: 0.40)
        }
    }

    static func videoEstimate(bitsPerPixel bpp: Double) -> SavingsEstimate {
        if bpp >= 0.30 { return SavingsEstimate(low: 0.75, high: 0.88) }
        if bpp >= 0.15 { return SavingsEstimate(low: 0.43, high: 0.85) }
        return SavingsEstimate(low: 0.15, high: 0.45)
    }

    private func defaultEstimate(for item: MediaItem) -> SavingsEstimate {
        item.kind == .photo ? SavingsEstimate(low: 0.30, high: 0.50) : SavingsEstimate(low: 0.40, high: 0.70)
    }
}
