import AVFoundation
import CoreMedia
import Foundation
import MediaSlimCore
import VideoToolbox

/// Re-encodes a video as HEVC at the lowest quality that still passes the SSIM threshold.
///
/// To keep the search fast, quality is chosen on short samples (three 2-second segments, or the
/// whole clip if it is short), then the full video is encoded once. What is preserved:
/// - HDR: 10-bit Main10 profile, the source color primaries, transfer function (HLG / PQ) and
///   matrix, and dynamic HDR metadata where the encoder supports it.
/// - Audio and timed metadata tracks: copied without re-encoding.
/// - Rotation (track transform) and file-level metadata (location, creation date, device).
/// The result is checked for duration and a decodable video track before it is returned.
public struct VideoCompressor: Sendable {
    public let tempStore: SecureTempStore

    /// Quality-mode search range (`AVVideoQualityKey`, 0...1).
    let qualitySearch = QualitySearch(range: 0.30...0.90, tolerance: 0.04, maxTrials: 6)
    /// Fallback when the encoder does not support quality mode: fraction of the source bitrate.
    let bitrateSearch = QualitySearch(range: 0.10...0.90, tolerance: 0.05, maxTrials: 6)
    /// Below this many bits per pixel per frame the source is already compressed hard.
    static let alreadyCompressedBitsPerPixel = 0.06
    static let framesPerSegment = 4
    static let comparisonMaxDimension = 960

    public init(tempStore: SecureTempStore) {
        self.tempStore = tempStore
    }

    enum RateControl: Sendable {
        case quality(Double)
        case bitrate(Int)
    }

    struct SourceInfo {
        let videoTrack: AVAssetTrack
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let frameRate: Double
        let duration: CMTime
        let videoBitrate: Double
        let otherTracksBitrate: Double
        let isTenBit: Bool
        let isHDR: Bool
        let colorProperties: [String: String]?
    }

    public func compress(input: URL, originalByteSize: Int64, options: ProcessingOptions) async throws -> CompressionOutcome {
        let asset = AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await Self.loadSourceInfo(asset)
        let seconds = info.duration.seconds
        guard seconds > 0, originalByteSize > 0 else { throw EngineError.unreadableInput }

        let pixels = Double(info.naturalSize.width * info.naturalSize.height)
        let bitsPerPixel = Double(originalByteSize * 8) / (pixels * max(info.frameRate, 1) * seconds)
        if bitsPerPixel < Self.alreadyCompressedBitsPerPixel {
            return .notWorthIt(bestSavingsFraction: nil)
        }

        let segments = Self.sampleSegments(duration: info.duration)
        let threshold = options.qualityLevel.videoSSIMThreshold
        let otherBytes = info.otherTracksBitrate * seconds / 8

        func evaluate(_ rate: RateControl, parameter: Double) async throws -> QualitySearch.Trial {
            var sampleBytes = 0.0, sampleSeconds = 0.0
            var scores: [Double] = []
            for segment in segments {
                let url = tempStore.makeFileURL(extension: "mov")
                defer { tempStore.remove(url) }
                try await Self.transcode(asset: asset, info: info, timeRange: segment, rate: rate, to: url, includeOtherTracks: false)
                sampleBytes += Double(tempStore.fileSize(url) ?? 0)
                sampleSeconds += segment.duration.seconds
                scores += try await Self.frameScores(original: asset, encoded: AVURLAsset(url: url), segment: segment)
            }
            guard sampleSeconds > 0, !scores.isEmpty else { throw EngineError.verificationFailed("no samples") }
            let mean = scores.reduce(0, +) / Double(scores.count)
            // One badly damaged frame should fail the trial even if the average looks fine.
            let score = min(mean, (scores.min() ?? mean) + 0.03)
            let projected = sampleBytes / sampleSeconds * seconds + otherBytes
            return QualitySearch.Trial(quality: parameter, byteSize: Int64(projected), score: score)
        }

        var chosen: RateControl
        do {
            let outcome = try await qualitySearch.run(threshold: threshold) { q in
                try await evaluate(.quality(q), parameter: q)
            }
            guard let best = outcome.best else { return .notWorthIt(bestSavingsFraction: nil) }
            chosen = .quality(best.quality)
        } catch EngineError.encoderUnavailable {
            engineLog.info("Quality rate control unavailable; using bitrate search")
            let outcome = try await bitrateSearch.run(threshold: threshold) { f in
                try await evaluate(.bitrate(Int(info.videoBitrate * f)), parameter: f)
            }
            guard let best = outcome.best else { return .notWorthIt(bestSavingsFraction: nil) }
            chosen = .bitrate(Int(info.videoBitrate * best.quality))
        }

        let output = tempStore.makeFileURL(extension: "mov")
        do {
            try await Self.transcode(asset: asset, info: info, timeRange: nil, rate: chosen, to: output, includeOtherTracks: true)
            try tempStore.protect(output)
            let bytes = tempStore.fileSize(output) ?? .max
            let savings = 1 - Double(bytes) / Double(originalByteSize)
            guard savings >= options.minimumSavingsFraction else {
                tempStore.remove(output)
                return .notWorthIt(bestSavingsFraction: savings)
            }
            let score = try await Self.verify(output: output, original: asset, info: info)
            guard score >= threshold - 0.01 else {
                tempStore.remove(output)
                return .notWorthIt(bestSavingsFraction: nil)
            }
            engineLog.debug("Video: saved \(savings, privacy: .public), SSIM \(score, privacy: .public)")
            return .compressed(url: output, byteSize: bytes, score: score)
        } catch {
            tempStore.remove(output)
            throw error
        }
    }

    // MARK: - Source inspection

    static func loadSourceInfo(_ asset: AVURLAsset) async throws -> SourceInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EngineError.unreadableInput
        }
        let (size, transform, fps, rate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        let duration = try await asset.load(.duration)

        var otherBitrate = 0.0
        for kind in [AVMediaType.audio, .metadata] {
            for other in try await asset.loadTracks(withMediaType: kind) {
                otherBitrate += Double(try await other.load(.estimatedDataRate))
            }
        }

        var isTenBit = false, isHDR = false
        var color: [String: String]?
        if let format = formats.first {
            let ext = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] ?? [:]
            let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
            let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
            let bits = (ext[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
            let hdrTransfers: Set<String> = [
                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            ]
            isHDR = transfer.map(hdrTransfers.contains) ?? false
            isTenBit = isHDR || (bits ?? 8) > 8
            if let primaries, let transfer, let matrix {
                color = [
                    AVVideoColorPrimariesKey: primaries,
                    AVVideoTransferFunctionKey: transfer,
                    AVVideoYCbCrMatrixKey: matrix,
                ]
            }
        }

        return SourceInfo(
            videoTrack: track,
            naturalSize: size,
            transform: transform,
            frameRate: Double(fps > 0 ? fps : 30),
            duration: duration,
            videoBitrate: Double(rate),
            otherTracksBitrate: otherBitrate,
            isTenBit: isTenBit,
            isHDR: isHDR,
            colorProperties: color
        )
    }

    /// Three 2-second windows spread over the clip, or the whole clip if it is short.
    static func sampleSegments(duration: CMTime) -> [CMTimeRange] {
        let total = duration.seconds
        let length = 2.0
        guard total > 8 else { return [CMTimeRange(start: .zero, duration: duration)] }
        return [0.15, 0.50, 0.85].map { fraction in
            let start = min(max(0, total * fraction - length / 2), total - length)
            return CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
        }
    }

    // MARK: - Encoding

    static func videoSettings(_ info: SourceInfo, rate: RateControl) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: info.frameRate,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoProfileLevelKey: info.isTenBit
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        switch rate {
        case let .quality(q): compression[AVVideoQualityKey] = q
        case let .bitrate(b): compression[AVVideoAverageBitRateKey] = max(b, 100_000)
        }
        if info.isHDR {
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = true
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(info.naturalSize.width),
            AVVideoHeightKey: Int(info.naturalSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let color = info.colorProperties { settings[AVVideoColorPropertiesKey] = color }
        return settings
    }

    static func transcode(
        asset: AVAsset,
        info: SourceInfo,
        timeRange: CMTimeRange?,
        rate: RateControl,
        to url: URL,
        includeOtherTracks: Bool
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
        if includeOtherTracks {
            writer.metadata = try await asset.load(.metadata)
        }

        let pixelFormat = info.isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: info.videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw EngineError.unreadableInput }
        reader.add(videoOutput)

        var settings = videoSettings(info, rate: rate)
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            // Drop the optional HDR metadata keys and try again before giving up.
            if var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
                compression.removeValue(forKey: kVTCompressionPropertyKey_HDRMetadataInsertionMode as String)
                compression.removeValue(forKey: kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String)
                settings[AVVideoCompressionPropertiesKey] = compression
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw EngineError.encoderUnavailable
            }
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = info.transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw EngineError.encoderUnavailable }
        writer.add(videoInput)

        var pairs: [UnsafeTransfer<(AVAssetReaderOutput, AVAssetWriterInput)>] = [UnsafeTransfer((videoOutput, videoInput))]

        if includeOtherTracks {
            for kind in [AVMediaType.audio, .metadata] {
                for track in try await asset.loadTracks(withMediaType: kind) {
                    let hint = try await track.load(.formatDescriptions).first
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    let input = AVAssetWriterInput(mediaType: kind, outputSettings: nil, sourceFormatHint: hint)
                    input.expectsMediaDataInRealTime = false
                    if kind == .audio { input.transform = .identity }
                    // A track that cannot be carried over is skipped rather than failing the file;
                    // the pixels and sound are what the user sees and hears.
                    guard reader.canAdd(output), writer.canAdd(input) else { continue }
                    reader.add(output)
                    writer.add(input)
                    pairs.append(UnsafeTransfer((output, input)))
                }
            }
        }

        guard reader.startReading() else {
            throw EngineError.encodeFailed(reader.error?.localizedDescription ?? "reader")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            // Most often: this device's encoder rejects the rate-control mode.
            throw EngineError.encoderUnavailable
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let cancelled = AtomicFlag()
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pair in pairs {
                    group.addTask { await pump(pair, cancelled: cancelled) }
                }
            }
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw EngineError.encodeFailed(reader.error?.localizedDescription ?? "read")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw EngineError.encodeFailed(writer.error?.localizedDescription ?? "write")
        }
    }

    /// Copies samples from one reader output to one writer input on a private serial queue.
    static func pump(_ pair: UnsafeTransfer<(AVAssetReaderOutput, AVAssetWriterInput)>, cancelled: AtomicFlag) async {
        let queue = DispatchQueue(label: "com.mediaslim.engine.pump", qos: .userInitiated)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = AtomicFlag()
            pair.value.1.requestMediaDataWhenReady(on: queue) {
                let (output, input) = pair.value
                func finish() {
                    input.markAsFinished()
                    if finished.claim() { continuation.resume() }
                }
                while input.isReadyForMoreMediaData {
                    if cancelled.isSet { finish(); return }
                    guard let sample = output.copyNextSampleBuffer() else { finish(); return }
                    if !input.append(sample) { finish(); return }
                }
            }
        }
    }

    // MARK: - Quality measurement

    static func frameScores(original: AVAsset, encoded: AVAsset, segment: CMTimeRange) async throws -> [Double] {
        let a = comparisonGenerator(for: original)
        let b = comparisonGenerator(for: encoded)
        // A sample written from a session that starts at `segment.start` may be rebased to begin
        // at zero. Detect that from its duration so frames are compared at the same moment.
        let encodedDuration = try await encoded.load(.duration)
        let rebased = segment.start.seconds > 0 && encodedDuration.seconds < segment.end.seconds - 0.1
        let n = framesPerSegment
        var scores: [Double] = []
        for i in 1...n {
            let offset = CMTimeMultiplyByRatio(segment.duration, multiplier: Int32(i), divisor: Int32(n + 1))
            let t = CMTimeAdd(segment.start, offset)
            let (ref, _) = try await a.image(at: t)
            let (cand, _) = try await b.image(at: rebased ? offset : t)
            let lr = try LumaExtractor.luma(from: ref, maxDimension: comparisonMaxDimension)
            let lc = try LumaExtractor.luma(from: cand, maxDimension: comparisonMaxDimension)
            guard lr.width == lc.width, lr.height == lc.height else {
                throw EngineError.verificationFailed("frame size")
            }
            scores.append(try SSIM.compute(lr, lc))
        }
        return scores
    }

    static func comparisonGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: comparisonMaxDimension, height: comparisonMaxDimension)
        return generator
    }

    /// Checks the full output: same duration, a video track, and frame quality at three points.
    static func verify(output url: URL, original: AVAsset, info: SourceInfo) async throws -> Double {
        let encoded = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await encoded.load(.duration)
        guard abs(duration.seconds - info.duration.seconds) < 0.25 else {
            throw EngineError.verificationFailed("duration")
        }
        guard let track = try await encoded.loadTracks(withMediaType: .video).first else {
            throw EngineError.verificationFailed("video track")
        }
        let transform = try await track.load(.preferredTransform)
        guard transform == info.transform else { throw EngineError.verificationFailed("rotation") }

        let probe = CMTimeRange(start: .zero, duration: info.duration)
        let scores = try await frameScores(original: original, encoded: encoded, segment: probe)
        return scores.reduce(0, +) / Double(scores.count)
    }
}
