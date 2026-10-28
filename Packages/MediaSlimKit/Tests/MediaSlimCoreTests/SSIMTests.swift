import Testing
@testable import MediaSlimCore

/// Deterministic pseudo-random generator so tests never flake.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func texturedImage(width: Int = 128, height: Int = 128, seed: UInt64 = 1) -> LumaImage {
    var rng = SplitMix64(state: seed)
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let base = (x * 2 + y) % 200
            px[y * width + x] = UInt8(min(255, base + Int(rng.next() % 40)))
        }
    }
    return LumaImage(width: width, height: height, pixels: px)
}

func addNoise(_ img: LumaImage, amplitude: Int, seed: UInt64 = 7) -> LumaImage {
    var rng = SplitMix64(state: seed)
    let px = img.pixels.map { v -> UInt8 in
        let delta = Int(rng.next() % UInt64(2 * amplitude + 1)) - amplitude
        return UInt8(max(0, min(255, Int(v) + delta)))
    }
    return LumaImage(width: img.width, height: img.height, pixels: px)
}

@Suite("SSIM")
struct SSIMTests {
    @Test("Identical images score 1")
    func identical() throws {
        let img = texturedImage()
        #expect(abs(try SSIM.compute(img, img) - 1.0) < 1e-9)
    }

    @Test("More distortion means a lower score")
    func monotonic() throws {
        let img = texturedImage()
        let light = try SSIM.compute(img, addNoise(img, amplitude: 4))
        let heavy = try SSIM.compute(img, addNoise(img, amplitude: 30))
        #expect(light < 1.0)
        #expect(heavy < light)
        #expect(heavy > 0)
    }

    @Test("Score is symmetric")
    func symmetric() throws {
        let a = texturedImage(seed: 3)
        let b = addNoise(a, amplitude: 10)
        #expect(abs(try SSIM.compute(a, b) - SSIM.compute(b, a)) < 1e-9)
    }

    @Test("Mismatched sizes are rejected")
    func sizeMismatch() {
        #expect(throws: SSIMError.sizeMismatch) {
            try SSIM.compute(texturedImage(width: 64, height: 64), texturedImage(width: 64, height: 72))
        }
    }

    @Test("Images smaller than a window are rejected")
    func tooSmall() {
        let tiny = LumaImage(width: 4, height: 4, pixels: [UInt8](repeating: 9, count: 16))
        #expect(throws: SSIMError.imageTooSmall) { try SSIM.compute(tiny, tiny) }
    }

    @Test("Crop is clamped to the image")
    func cropClamp() {
        let img = texturedImage(width: 20, height: 10)
        let c = img.crop(x: 15, y: 5, width: 50, height: 50)
        #expect(c.width == 5 && c.height == 5)
        #expect(c.pixels[0] == img.pixels[5 * 20 + 15])
    }

    @Test("Tile sampler prefers detailed regions and stays inside the image")
    func tileSampler() throws {
        // Left half flat, right half textured.
        let w = 256, h = 128
        var px = [UInt8](repeating: 128, count: w * h)
        let tex = texturedImage(width: w, height: h, seed: 11)
        for y in 0..<h { for x in (w / 2)..<w { px[y * w + x] = tex.pixels[y * w + x] } }
        let img = LumaImage(width: w, height: h, pixels: px)

        let tiles = TileSampler.selectTiles(in: img, tileSize: 64, detailed: 2, spread: 2)
        #expect(!tiles.isEmpty)
        for t in tiles {
            #expect(t.x + t.size <= w && t.y + t.size <= h)
        }
        #expect(tiles.prefix(2).allSatisfy { $0.x >= w / 2 })
        #expect(abs(try TileSampler.score(reference: img, candidate: img, tiles: tiles) - 1) < 1e-9)
    }
}
