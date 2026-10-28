import CoreGraphics
import Foundation
import ImageIO
import MediaSlimCore
import UniformTypeIdentifiers

/// Re-encodes a photo as HEIC at the lowest quality that still passes the SSIM threshold.
///
/// What is preserved, and how:
/// - Pixels: the decoded image is re-encoded at its original size and bit depth.
/// - Orientation, EXIF, GPS, TIFF and maker data: the source properties are passed through.
/// - HDR gain map, depth, portrait matte and segmentation mattes: copied as auxiliary data,
///   so the photo still looks bright on HDR screens and portrait effects stay editable.
/// The result is decoded and checked before it is returned; any mismatch is an error.
public struct ImageCompressor: Sendable {
    public let tempStore: SecureTempStore
    public let search: QualitySearch

    public init(tempStore: SecureTempStore, search: QualitySearch = QualitySearch(range: 0.30...0.95, tolerance: 0.025, maxTrials: 7)) {
        self.tempStore = tempStore
        self.search = search
    }

    public static var isHEICEncodingAvailable: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }

    public func compress(input: URL, originalByteSize: Int64, options: ProcessingOptions) async throws -> CompressionOutcome {
        guard Self.isHEICEncodingAvailable else { throw EngineError.encoderUnavailable }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw EngineError.unreadableInput
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw EngineError.decodeFailed
        }
        let auxiliary = Self.auxiliaryData(from: source)
        let reference = try LumaExtractor.luma(from: image)
        let tiles = TileSampler.selectTiles(in: reference)

        var encodedByQuality: [Double: Data] = [:]
        let outcome = try await search.run(threshold: options.qualityLevel.photoSSIMThreshold) { quality in
            try Task.checkCancellation()
            let data = try Self.encode(image: image, properties: properties, auxiliary: auxiliary, quality: quality)
            let candidate = try Self.decodeLuma(data)
            guard candidate.width == reference.width, candidate.height == reference.height else {
                throw EngineError.verificationFailed("dimensions")
            }
            let score = try TileSampler.score(reference: reference, candidate: candidate, tiles: tiles)
            encodedByQuality[quality] = data
            return QualitySearch.Trial(quality: quality, byteSize: Int64(data.count), score: score)
        }

        guard let best = outcome.best, let data = encodedByQuality[best.quality], originalByteSize > 0 else {
            return .notWorthIt(bestSavingsFraction: nil)
        }
        let savings = 1 - Double(best.byteSize) / Double(originalByteSize)
        guard savings >= options.minimumSavingsFraction else {
            return .notWorthIt(bestSavingsFraction: savings)
        }

        let url = tempStore.makeFileURL(extension: "heic")
        do {
            try tempStore.write(data, to: url)
            try Self.verify(output: url, originalProperties: properties, expectedAuxiliaryCount: auxiliary.count)
        } catch {
            tempStore.remove(url)
            throw error
        }
        engineLog.debug("Photo: quality \(best.quality, privacy: .public), SSIM \(best.score, privacy: .public), saved \(savings, privacy: .public)")
        return .compressed(url: url, byteSize: Int64(data.count), score: best.score)
    }

    // MARK: - Encoding

    static func encode(image: CGImage, properties: [CFString: Any], auxiliary: [(CFString, CFDictionary)], quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw EngineError.encoderUnavailable
        }
        var imageProperties = properties
        // The encoder derives these from the image; stale values would conflict.
        imageProperties.removeValue(forKey: kCGImagePropertyPixelWidth)
        imageProperties.removeValue(forKey: kCGImagePropertyPixelHeight)
        imageProperties.removeValue(forKey: kCGImagePropertyFileSize)
        imageProperties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, imageProperties as CFDictionary)
        for (type, info) in auxiliary {
            CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
        }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed("finalize") }
        return data as Data
    }

    static func decodeLuma(_ data: Data) throws -> LumaImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw EngineError.decodeFailed
        }
        return try LumaExtractor.luma(from: image)
    }

    // MARK: - Auxiliary images

    static var auxiliaryTypes: [CFString] {
        var types: [CFString] = [
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
        ]
        if #available(iOS 18, macOS 15, *) {
            types.append(kCGImageAuxiliaryDataTypeISOGainMap)
        }
        return types
    }

    static func auxiliaryData(from source: CGImageSource) -> [(CFString, CFDictionary)] {
        auxiliaryTypes.compactMap { type in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type).map { (type, $0) }
        }
    }

    // MARK: - Verification

    /// Re-reads the written file and checks what the user would notice if it were wrong.
    static func verify(output url: URL, originalProperties: [CFString: Any], expectedAuxiliaryCount: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw EngineError.verificationFailed("unreadable output")
        }
        func int(_ dict: [CFString: Any], _ key: CFString) -> Int? { (dict[key] as? NSNumber)?.intValue }

        if let w = int(originalProperties, kCGImagePropertyPixelWidth), w != int(props, kCGImagePropertyPixelWidth) {
            throw EngineError.verificationFailed("width")
        }
        if let h = int(originalProperties, kCGImagePropertyPixelHeight), h != int(props, kCGImagePropertyPixelHeight) {
            throw EngineError.verificationFailed("height")
        }
        let originalOrientation = int(originalProperties, kCGImagePropertyOrientation) ?? 1
        if originalOrientation != (int(props, kCGImagePropertyOrientation) ?? 1) {
            throw EngineError.verificationFailed("orientation")
        }
        if originalProperties[kCGImagePropertyGPSDictionary] != nil, props[kCGImagePropertyGPSDictionary] == nil {
            throw EngineError.verificationFailed("location")
        }
        let written = auxiliaryData(from: source).count
        if written < expectedAuxiliaryCount {
            throw EngineError.verificationFailed("auxiliary images")
        }
    }
}
