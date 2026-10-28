import AVFoundation
import Foundation
import ImageIO
import MediaSlimCore
@testable import MediaSlimEngine
import Testing

@Suite("Image compressor", .enabled(if: ImageCompressor.isHEICEncodingAvailable))
struct ImageCompressorTests {
    @Test("Shrinks a camera-quality HEIC and keeps orientation and location")
    func compressesAndPreservesMetadata() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.heic")
        try Fixtures.writeCameraLikeHEIC(to: input)
        let originalSize = Fixtures.size(input)

        let store = try SecureTempStore(directory: dir.appendingPathComponent("work"))
        let compressor = ImageCompressor(tempStore: store)
        let outcome = try await compressor.compress(input: input, originalByteSize: originalSize, options: ProcessingOptions())

        guard case let .compressed(url, bytes, score) = outcome else {
            Issue.record("Expected a compressed result, got \(outcome)")
            return
        }
        #expect(bytes < originalSize)
        #expect(score >= QualityLevel.balanced.photoSSIMThreshold)
        #expect(url.path.hasPrefix(store.directory.path))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
        #expect(props[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test("Stricter quality never produces a smaller file than a looser one")
    func qualityLevelsAreOrdered() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.heic")
        try Fixtures.writeCameraLikeHEIC(to: input)
        let size = Fixtures.size(input)
        let compressor = ImageCompressor(tempStore: try SecureTempStore(directory: dir.appendingPathComponent("work")))

        func bytes(_ level: QualityLevel) async throws -> Int64 {
            let options = ProcessingOptions(qualityLevel: level, minimumSavingsFraction: 0)
            if case let .compressed(_, b, _) = try await compressor.compress(input: input, originalByteSize: size, options: options) {
                return b
            }
            return size
        }
        let savings = try await bytes(.maximumSavings)
        let quality = try await bytes(.maximumQuality)
        #expect(savings <= quality)
    }

    @Test("Reports not worth it when the minimum saving cannot be met")
    func notWorthIt() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.heic")
        try Fixtures.writeCameraLikeHEIC(to: input)
        let compressor = ImageCompressor(tempStore: try SecureTempStore(directory: dir.appendingPathComponent("work")))
        let options = ProcessingOptions(minimumSavingsFraction: 0.999)
        let outcome = try await compressor.compress(input: input, originalByteSize: Fixtures.size(input), options: options)
        if case .compressed = outcome { Issue.record("Should not compress") }
    }

    @Test("Unreadable input is an error, not a crash")
    func unreadable() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("broken.heic")
        try Data("not an image".utf8).write(to: input)
        let compressor = ImageCompressor(tempStore: try SecureTempStore(directory: dir.appendingPathComponent("work")))
        await #expect(throws: EngineError.self) {
            _ = try await compressor.compress(input: input, originalByteSize: 100, options: ProcessingOptions())
        }
    }
}

@Suite("Video compressor")
struct VideoCompressorTests {
    @Test("Shrinks a high-bitrate movie and keeps its duration")
    func compressesHighBitrate() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.mov")
        try await Fixtures.writeMovie(to: input, seconds: 3, bitrate: 12_000_000)
        let originalSize = Fixtures.size(input)

        let compressor = VideoCompressor(tempStore: try SecureTempStore(directory: dir.appendingPathComponent("work")))
        let outcome = try await compressor.compress(input: input, originalByteSize: originalSize, options: ProcessingOptions())

        guard case let .compressed(url, bytes, _) = outcome else {
            Issue.record("Expected a compressed result, got \(outcome)")
            return
        }
        #expect(bytes < originalSize)
        let original = try await AVURLAsset(url: input).load(.duration).seconds
        let encoded = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(original - encoded) < 0.25)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
    }

    @Test("Skips a movie that is already compressed hard")
    func skipsLowBitrate() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.mov")
        try await Fixtures.writeMovie(to: input, seconds: 2, bitrate: 150_000)
        let compressor = VideoCompressor(tempStore: try SecureTempStore(directory: dir.appendingPathComponent("work")))
        let outcome = try await compressor.compress(input: input, originalByteSize: Fixtures.size(input), options: ProcessingOptions())
        if case .compressed = outcome { Issue.record("A hard-compressed movie should be left alone") }
    }

    @Test("Sample windows stay inside the clip")
    func segments() {
        let long = VideoCompressor.sampleSegments(duration: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(long.count == 3)
        for s in long {
            #expect(s.start.seconds >= 0)
            #expect(s.end.seconds <= 60.0001)
        }
        let short = VideoCompressor.sampleSegments(duration: CMTime(seconds: 5, preferredTimescale: 600))
        #expect(short.count == 1)
        #expect(short[0].duration.seconds == 5)
    }
}

@Suite("Secure temp store")
struct SecureTempStoreTests {
    @Test("Refuses to touch files outside its folder")
    func confinement() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SecureTempStore(directory: dir.appendingPathComponent("work"))
        let outside = dir.appendingPathComponent("user-file.txt")
        try Data("keep me".utf8).write(to: outside)
        store.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(throws: (any Error).self) { try store.write(Data(), to: outside) }
    }

    @Test("Purge empties the folder")
    func purge() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SecureTempStore(directory: dir.appendingPathComponent("work"))
        try store.write(Data([1, 2, 3]), to: store.makeFileURL(extension: "bin"))
        store.purgeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }
}
