import CoreGraphics
import Foundation
import MediaSlimCore
import os

public enum EngineError: Error, Equatable, Sendable {
    case unreadableInput
    case decodeFailed
    case encodeFailed(String)
    /// The device cannot encode this format (for example HEVC on very old hardware).
    case encoderUnavailable
    /// The output did not match the original (dimensions, duration, metadata). Never replaced.
    case verificationFailed(String)
}

let engineLog = Logger(subsystem: "com.mediaslim.engine", category: "engine")

/// Converts decoded images to 8-bit luma for SSIM.
enum LumaExtractor {
    /// - Parameter maxDimension: downscale so the longer side is at most this many pixels.
    static func luma(from image: CGImage, maxDimension: Int? = nil) throws -> LumaImage {
        var width = image.width, height = image.height
        if let maxDimension, max(width, height) > maxDimension {
            let scale = Double(maxDimension) / Double(max(width, height))
            width = max(8, Int((Double(width) * scale).rounded()))
            height = max(8, Int((Double(height) * scale).rounded()))
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EngineError.decodeFailed }
        return LumaImage(width: width, height: height, pixels: pixels)
    }
}

/// Moves a value that is not `Sendable` into a context the compiler cannot prove safe.
///
/// Used only for AVFoundation reader/writer objects that Apple documents as safe to drive from
/// the serial queue passed to `requestMediaDataWhenReady(on:using:)`. Each wrapped value is
/// touched by exactly one queue at a time.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A flag that can be set from any thread and read from any thread.
final class AtomicFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
    /// Sets the flag and returns `true` only for the first caller.
    func claim() -> Bool {
        state.withLock { value in
            if value { return false }
            value = true
            return true
        }
    }
}
