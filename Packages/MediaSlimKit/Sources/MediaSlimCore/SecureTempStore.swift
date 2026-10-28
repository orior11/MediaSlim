import Foundation

/// The only place the app writes media to disk.
///
/// - Lives in Caches, so the system may reclaim it and it is never backed up.
/// - Every file is protected with `completeUntilFirstUserAuthentication`: encrypted at rest and
///   unreadable before the first unlock after a reboot, yet still usable by background processing.
/// - Files get random names, are deleted as soon as an item finishes, and the whole folder is
///   purged at launch, so nothing outlives a crash for long.
public final class SecureTempStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) throws {
        let fm = FileManager.default
        let base: URL
        if let directory {
            base = directory
        } else {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            base = caches.appendingPathComponent("MediaSlimWork", isDirectory: true)
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: Self.protectionAttributes)
        var excluded = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        self.directory = base
    }

    static var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    /// A fresh, unpredictable path inside the store. Nothing is created yet.
    public func makeFileURL(extension ext: String) -> URL {
        directory.appendingPathComponent(UUID().uuidString, isDirectory: false).appendingPathExtension(ext)
    }

    public func write(_ data: Data, to url: URL) throws {
        try checkInside(url)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    /// Applies protection to a file another API created (for example AVAssetWriter).
    public func protect(_ url: URL) throws {
        try checkInside(url)
        if let attributes = Self.protectionAttributes {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    public func remove(_ url: URL) {
        guard (try? checkInside(url)) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes everything in the store. Called at launch and after each run.
    public func purgeAll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    public func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Refuses paths outside the store, so a bug elsewhere can never delete user files.
    private func checkInside(_ url: URL) throws {
        let dir = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
