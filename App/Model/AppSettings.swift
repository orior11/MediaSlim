import Foundation
import MediaSlimCore
import Observation

/// User preferences, stored in UserDefaults. Holds no personal data.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    var qualityLevel: QualityLevel { didSet { defaults.set(qualityLevel.rawValue, forKey: Keys.quality) } }
    /// The last choice, offered as the default next time. The user still confirms it every run.
    var lastOriginalHandling: OriginalHandling { didSet { defaults.set(lastOriginalHandling.rawValue, forKey: Keys.handling) } }
    var includePhotos: Bool { didSet { defaults.set(includePhotos, forKey: Keys.photos) } }
    var includeVideos: Bool { didSet { defaults.set(includeVideos, forKey: Keys.videos) } }
    var allowCloudDownloads: Bool { didSet { defaults.set(allowCloudDownloads, forKey: Keys.cloud) } }
    var continueWhileCharging: Bool { didSet { defaults.set(continueWhileCharging, forKey: Keys.charging) } }

    private enum Keys {
        static let onboarding = "settings.onboardingDone"
        static let quality = "settings.quality"
        static let handling = "settings.originalHandling"
        static let photos = "settings.includePhotos"
        static let videos = "settings.includeVideos"
        static let cloud = "settings.allowCloudDownloads"
        static let charging = "settings.continueWhileCharging"
        static let all = [onboarding, quality, handling, photos, videos, cloud, charging]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        qualityLevel = defaults.string(forKey: Keys.quality).flatMap(QualityLevel.init(rawValue:)) ?? .balanced
        lastOriginalHandling = defaults.string(forKey: Keys.handling).flatMap(OriginalHandling.init(rawValue:)) ?? .replace
        includePhotos = defaults.object(forKey: Keys.photos) as? Bool ?? true
        includeVideos = defaults.object(forKey: Keys.videos) as? Bool ?? true
        allowCloudDownloads = defaults.object(forKey: Keys.cloud) as? Bool ?? false
        continueWhileCharging = defaults.object(forKey: Keys.charging) as? Bool ?? true
    }

    func resetAll() {
        for key in Keys.all { defaults.removeObject(forKey: key) }
        hasCompletedOnboarding = false
        qualityLevel = .balanced
        lastOriginalHandling = .replace
        includePhotos = true
        includeVideos = true
        allowCloudDownloads = false
        continueWhileCharging = true
    }
}
