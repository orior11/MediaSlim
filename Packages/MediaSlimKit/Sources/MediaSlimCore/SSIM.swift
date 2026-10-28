import Foundation

/// An 8-bit single-channel image (luma), stored row by row without padding.
public struct LumaImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Image must not be empty")
        precondition(pixels.count == width * height, "Pixel count must equal width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A copy of the rectangle starting at (x, y). The rectangle is clamped to the image.
    public func crop(x: Int, y: Int, width w: Int, height h: Int) -> LumaImage {
        let x0 = max(0, min(x, width - 1)), y0 = max(0, min(y, height - 1))
        let cw = max(1, min(w, width - x0)), ch = max(1, min(h, height - y0))
        var out = [UInt8](repeating: 0, count: cw * ch)
        out.withUnsafeMutableBufferPointer { dst in
            pixels.withUnsafeBufferPointer { src in
                for row in 0..<ch {
                    let s = (y0 + row) * width + x0
                    for col in 0..<cw { dst[row * cw + col] = src[s + col] }
                }
            }
        }
        return LumaImage(width: cw, height: ch, pixels: out)
    }
}

public enum SSIMError: Error, Equatable {
    case sizeMismatch
    case imageTooSmall
}

/// Structural similarity (Wang et al. 2004) on luma, using square windows.
///
/// Uses summed-area tables so each window costs O(1). Windows are 8×8 with a stride of 4,
/// which tracks the Gaussian-window SSIM used in the research phase to within about 0.002.
public enum SSIM {
    public static let windowSize = 8
    public static let stride = 4

    private static let c1 = (0.01 * 255.0) * (0.01 * 255.0)
    private static let c2 = (0.03 * 255.0) * (0.03 * 255.0)

    /// Mean SSIM between two images of identical size. 1.0 means identical.
    public static func compute(_ a: LumaImage, _ b: LumaImage) throws -> Double {
        guard a.width == b.width, a.height == b.height else { throw SSIMError.sizeMismatch }
        guard a.width >= windowSize, a.height >= windowSize else { throw SSIMError.imageTooSmall }

        let w = a.width, h = a.height
        let tw = w + 1
        // Summed-area tables with one row and column of zero padding.
        var sa = [Double](repeating: 0, count: tw * (h + 1))
        var sb = sa, saa = sa, sbb = sa, sab = sa

        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in 0..<h {
                    var ra = 0.0, rb = 0.0, raa = 0.0, rbb = 0.0, rab = 0.0
                    let rowBase = y * w
                    let up = y * tw, cur = (y + 1) * tw
                    for x in 0..<w {
                        let va = Double(pa[rowBase + x]), vb = Double(pb[rowBase + x])
                        ra += va; rb += vb; raa += va * va; rbb += vb * vb; rab += va * vb
                        let i = cur + x + 1, j = up + x + 1
                        sa[i] = sa[j] + ra
                        sb[i] = sb[j] + rb
                        saa[i] = saa[j] + raa
                        sbb[i] = sbb[j] + rbb
                        sab[i] = sab[j] + rab
                    }
                }
            }
        }

        @inline(__always) func boxSum(_ t: [Double], _ x: Int, _ y: Int, _ n: Int) -> Double {
            t[(y + n) * tw + (x + n)] - t[y * tw + (x + n)] - t[(y + n) * tw + x] + t[y * tw + x]
        }

        let n = windowSize
        let count = Double(n * n)
        var total = 0.0
        var windows = 0
        var y = 0
        while y + n <= h {
            var x = 0
            while x + n <= w {
                let ma = boxSum(sa, x, y, n) / count
                let mb = boxSum(sb, x, y, n) / count
                let va = boxSum(saa, x, y, n) / count - ma * ma
                let vb = boxSum(sbb, x, y, n) / count - mb * mb
                let cov = boxSum(sab, x, y, n) / count - ma * mb
                let num = (2 * ma * mb + c1) * (2 * cov + c2)
                let den = (ma * ma + mb * mb + c1) * (va + vb + c2)
                total += num / den
                windows += 1
                x += stride
            }
            y += stride
        }
        return total / Double(windows)
    }
}

/// Chooses which regions of a large photo to compare.
///
/// Comparing a full 24 MP frame on every search step is slow, and a frame-wide average
/// hides local damage. The sampler takes the most detailed tiles (where compression shows
/// first) plus evenly spread tiles (so the score stays representative of the whole image).
public enum TileSampler {
    public struct Tile: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let size: Int
    }

    public static func selectTiles(in image: LumaImage, tileSize: Int = 384, detailed: Int = 4, spread: Int = 4) -> [Tile] {
        let size = min(tileSize, image.width, image.height)
        let cols = max(1, image.width / size), rows = max(1, image.height / size)
        var candidates: [(tile: Tile, variance: Double)] = []
        candidates.reserveCapacity(cols * rows)

        for r in 0..<rows {
            for c in 0..<cols {
                let tile = Tile(x: c * size, y: r * size, size: size)
                candidates.append((tile, variance(of: image, tile: tile)))
            }
        }

        var chosen: [Tile] = []
        for entry in candidates.sorted(by: { $0.variance > $1.variance }).prefix(detailed) {
            chosen.append(entry.tile)
        }
        if spread > 0 {
            let step = max(1, candidates.count / spread)
            var i = step / 2
            while chosen.count < detailed + spread, i < candidates.count {
                let tile = candidates[i].tile
                if !chosen.contains(tile) { chosen.append(tile) }
                i += step
            }
        }
        return chosen
    }

    /// Variance sampled on a sparse grid; enough to rank tiles by detail.
    static func variance(of image: LumaImage, tile: Tile) -> Double {
        var sum = 0.0, sumSq = 0.0, n = 0.0
        var y = tile.y
        while y < tile.y + tile.size {
            var x = tile.x
            let base = y * image.width
            while x < tile.x + tile.size {
                let v = Double(image.pixels[base + x])
                sum += v; sumSq += v * v; n += 1
                x += 4
            }
            y += 4
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Mean SSIM over the given tiles. Both images must have the same size.
    public static func score(reference: LumaImage, candidate: LumaImage, tiles: [Tile]) throws -> Double {
        guard reference.width == candidate.width, reference.height == candidate.height else {
            throw SSIMError.sizeMismatch
        }
        guard !tiles.isEmpty else { return try SSIM.compute(reference, candidate) }
        var total = 0.0
        for t in tiles {
            total += try SSIM.compute(
                reference.crop(x: t.x, y: t.y, width: t.size, height: t.size),
                candidate.crop(x: t.x, y: t.y, width: t.size, height: t.size)
            )
        }
        return total / Double(tiles.count)
    }
}
