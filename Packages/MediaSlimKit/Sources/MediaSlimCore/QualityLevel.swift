import Foundation

/// How close to the original a compressed file must stay.
///
/// Thresholds come from the research phase: SSIM 0.98 on still images and VMAF 95 on video
/// were judged visually indistinguishable at 1:1 crops. On device the video check uses SSIM
/// on sampled frames as a proxy for VMAF, so its thresholds are set slightly lower.
/// Both must be re-calibrated against the hardware encoder in the device prototype.
public enum QualityLevel: String, Codable, Sendable, CaseIterable {
    case maximumQuality
    case balanced
    case maximumSavings

    /// Minimum SSIM, on luma, between a compressed photo and its original.
    public var photoSSIMThreshold: Double {
        switch self {
        case .maximumQuality: 0.99
        case .balanced: 0.98
        case .maximumSavings: 0.97
        }
    }

    /// Minimum mean SSIM, on luma of sampled frames, between a compressed video and its original.
    public var videoSSIMThreshold: Double {
        switch self {
        case .maximumQuality: 0.985
        case .balanced: 0.975
        case .maximumSavings: 0.965
        }
    }

    public func threshold(for kind: MediaKind) -> Double {
        kind == .photo ? photoSSIMThreshold : videoSSIMThreshold
    }
}

/// Settings for one processing run.
public struct ProcessingOptions: Codable, Sendable, Equatable {
    public var qualityLevel: QualityLevel
    public var originalHandling: OriginalHandling
    /// Let Photos download originals that are stored only in iCloud.
    public var allowCloudDownloads: Bool
    /// Below this saving the original is left untouched (0.1 = 10%).
    public var minimumSavingsFraction: Double

    public init(
        qualityLevel: QualityLevel = .balanced,
        originalHandling: OriginalHandling = .replace,
        allowCloudDownloads: Bool = false,
        minimumSavingsFraction: Double = 0.10
    ) {
        self.qualityLevel = qualityLevel
        self.originalHandling = originalHandling
        self.allowCloudDownloads = allowCloudDownloads
        self.minimumSavingsFraction = minimumSavingsFraction
    }
}
