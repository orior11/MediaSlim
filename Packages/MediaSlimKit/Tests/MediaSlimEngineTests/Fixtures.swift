import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds synthetic media on the fly so the tests need no binary fixtures.
enum Fixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaSlimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A photo-like image: smooth gradients, edges and fine texture.
    static func makeImage(width: Int = 1600, height: Int = 1200, seed: UInt32 = 42) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state = seed
        func rand() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let stripe = ((x / 40) + (y / 40)) % 2 == 0 ? 30 : 0
                let grain = Int(rand() % 24)
                pixels[i] = UInt8(min(255, x * 255 / width / 2 + stripe + grain))
                pixels[i + 1] = UInt8(min(255, y * 255 / height / 2 + 60 + grain))
                pixels[i + 2] = UInt8(min(255, (x + y) * 255 / (width + height) + grain))
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Writes a high-quality HEIC with orientation and location, like a camera would.
    static func writeCameraLikeHEIC(to url: URL, image: CGImage = makeImage()) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.77,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 35.21,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes an H.264 movie with moving texture at the given bitrate.
    static func writeMovie(to url: URL, seconds: Int = 3, width: Int = 640, height: Int = 480, bitrate: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    // Fixed texture that pans across the frame: realistic motion, no temporal noise.
                    let sx = x + frame * 4
                    let grain = Int((UInt32(truncatingIfNeeded: sx &* 73_856_093) ^ UInt32(truncatingIfNeeded: y &* 19_349_663)) >> 28)
                    let v = UInt8(min(255, (sx % 255) / 2 + ((y / 30) % 2) * 60 + grain))
                    let p = base + y * stride + x * 4
                    p[0] = v; p[1] = UInt8(255 - Int(v)); p[2] = UInt8((Int(v) + y) % 256); p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
