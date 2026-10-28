import Testing
@testable import MediaSlimCore

@Suite("Eligibility")
struct EligibilityTests {
    let policy = EligibilityPolicy()

    func photo(bytes: Int64 = 3_000_000, type: String = "public.heic", traits: Set<MediaTrait> = []) -> MediaItem {
        MediaItem(id: "p", kind: .photo, byteSize: bytes, pixelWidth: 4284, pixelHeight: 5712,
                  uniformTypeIdentifier: type, traits: traits)
    }

    func video(bytes: Int64, seconds: Double, width: Int = 1920, height: Int = 1080) -> MediaItem {
        MediaItem(id: "v", kind: .video, byteSize: bytes, pixelWidth: width, pixelHeight: height,
                  duration: seconds, uniformTypeIdentifier: "com.apple.quicktime-movie")
    }

    @Test("A camera HEIC photo is eligible")
    func cameraPhoto() {
        #expect(policy.evaluate(photo()).isEligible)
    }

    @Test("Structurally fragile items are skipped with the right reason", arguments: [
        (MediaTrait.livePhoto, SkipReason.livePhoto),
        (.edited, .edited),
        (.raw, .raw),
        (.highFrameRate, .slowMotion),
        (.cinematic, .cinematic),
        (.spatial, .spatial),
        (.notInUserLibrary, .notInUserLibrary),
    ])
    func fragile(trait: MediaTrait, reason: SkipReason) {
        #expect(policy.evaluate(photo(traits: [trait])) == .skipped(reason))
    }

    @Test("Edited wins over other traits, so the user hears the most important reason")
    func priority() {
        #expect(policy.evaluate(photo(traits: [.livePhoto, .edited])) == .skipped(.edited))
    }

    @Test("Unsupported formats are skipped")
    func unsupported() {
        #expect(policy.evaluate(photo(type: "com.compuserve.gif")) == .skipped(.unsupportedFormat))
    }

    @Test("Tiny files are skipped")
    func tiny() {
        #expect(policy.evaluate(photo(bytes: 20_000)) == .skipped(.tooSmall))
    }

    @Test("Items created by the app are not processed twice")
    func alreadyProcessed() {
        let p = EligibilityPolicy(processedAssetIDs: ["p"])
        #expect(p.evaluate(photo()) == .skipped(.alreadyProcessed))
    }

    // Numbers below are the real files from the research experiment.

    @Test("A messaging-app video is recognised as already compressed")
    func whatsappVideo() {
        let v = video(bytes: 4_070_448, seconds: 31.12, width: 1024, height: 576)
        #expect(policy.evaluate(v) == .skipped(.alreadyCompressed))
    }

    @Test("An iPhone camera video is eligible")
    func iphoneVideo() {
        let v = video(bytes: 9_393_469, seconds: 7.0)
        guard case let .eligible(estimate) = policy.evaluate(v) else {
            Issue.record("Expected eligible")
            return
        }
        #expect(estimate.low >= 0.4)
    }

    @Test("A high-bitrate export is eligible with a high estimate")
    func generousExport() {
        let v = video(bytes: 13_268_276, seconds: 10.33, width: 720, height: 1280)
        guard case let .eligible(estimate) = policy.evaluate(v) else {
            Issue.record("Expected eligible")
            return
        }
        #expect(estimate.high >= 0.85)
    }

    @Test("Unknown size still lets the engine decide")
    func unknownSize() {
        let item = MediaItem(id: "x", kind: .photo, byteSize: nil, pixelWidth: 100, pixelHeight: 100)
        #expect(policy.evaluate(item).isEligible)
    }

    @Test("Savings estimate is clamped to 0...1")
    func clamp() {
        let e = SavingsEstimate(low: -0.2, high: 1.4)
        #expect(e.low == 0 && e.high == 1)
    }
}
