import Foundation
import MediaSlimCore

/// The engine's single entry point: picks the photo or video path.
public struct MediaCompressor: MediaCompressing {
    let images: ImageCompressor
    let videos: VideoCompressor

    public init(tempStore: SecureTempStore) {
        images = ImageCompressor(tempStore: tempStore)
        videos = VideoCompressor(tempStore: tempStore)
    }

    public func compress(input: URL, kind: MediaKind, originalByteSize: Int64, options: ProcessingOptions) async throws -> CompressionOutcome {
        switch kind {
        case .photo: try await images.compress(input: input, originalByteSize: originalByteSize, options: options)
        case .video: try await videos.compress(input: input, originalByteSize: originalByteSize, options: options)
        }
    }
}
