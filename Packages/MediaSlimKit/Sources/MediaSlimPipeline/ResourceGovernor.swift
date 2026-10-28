import Foundation
import MediaSlimCore

/// Why processing is on hold.
public enum PauseReason: String, Sendable, Hashable, CaseIterable {
    /// The user tapped Pause.
    case user
    /// The device is hot. Encoding would make it hotter and slow everything down.
    case thermal
    /// Low Power Mode is on. The user asked the phone to save battery.
    case lowPower
    /// Free space is almost gone; originals must be deleted before going on.
    case lowStorage
}

/// Reports conditions that should pause heavy work.
public protocol ResourceMonitoring: Sendable {
    func blockers() -> Set<PauseReason>
}

public struct SystemResourceMonitor: ResourceMonitoring {
    public init() {}

    public func blockers() -> Set<PauseReason> {
        var reasons: Set<PauseReason> = []
        let info = ProcessInfo.processInfo
        switch info.thermalState {
        case .serious, .critical: reasons.insert(.thermal)
        default: break
        }
        if info.isLowPowerModeEnabled { reasons.insert(.lowPower) }
        return reasons
    }
}

public struct SystemStorageInspector: StorageInspecting {
    public init() {}

    public func availableBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
