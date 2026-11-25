import CoreGraphics
import Foundation

/// Finds the pips in a photo of dominoes laid face up.
///
/// The tiles are the light, low-color parts of the picture. A pip is a small round patch that is
/// not tile-colored (dark, or a strong color) and is completely surrounded by tile. That rules out
/// the table (it reaches the edge of the photo), the gaps between tiles and the line across each
/// tile (not round), and specks (much smaller than the other pips).
enum PipCounter {
    struct Result {
        /// Each pip's bounding box, as fractions (0–1) of the photo's width and height.
        var pips: [CGRect]
        var count: Int { pips.count }
    }

    static func count(_ image: CGImage, maxSide: Int = 1000) -> Result {
        let scale = min(1.0, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return Result(pips: []) }

        // Brightness and colorfulness of every pixel.
        var lum = [UInt8](repeating: 0, count: w * h)
        var sat = [Float](repeating: 0, count: w * h)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            let r = Float(rgba[4 * i]), g = Float(rgba[4 * i + 1]), b = Float(rgba[4 * i + 2])
            let l = UInt8(min(255, 0.299 * r + 0.587 * g + 0.114 * b))
            lum[i] = l
            histogram[Int(l)] += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            sat[i] = mx > 0 ? (mx - mn) / mx : 0
        }
        let threshold = otsu(histogram, total: w * h)

        // First pass: tile = brighter than the table and not strongly colored. On a dark table this
        // cutoff is low enough that gray pips pass as tile, so it only locates the tiles.
        var rough = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { rough[i] = Int(lum[i]) > threshold && sat[i] < 0.4 }

        // Second pass: compare each pixel with the white of the tiles around it (the average of
        // first-pass tile pixels in a nearby window, which also follows uneven lighting). Anything
        // clearly darker than that, such as a gray pip, is not tile.
        let radius = max(6, min(w, h) / 14)
        var sumL = [Double](repeating: 0, count: (w + 1) * (h + 1))
        var sumN = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowL = 0.0, rowN = 0.0
            for x in 0..<w {
                let i = y * w + x
                if rough[i] { rowL += Double(lum[i]); rowN += 1 }
                let k = (y + 1) * (w + 1) + (x + 1)
                sumL[k] = sumL[k - (w + 1)] + rowL
                sumN[k] = sumN[k - (w + 1)] + rowN
            }
        }
        func boxSum(_ s: [Double], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            s[(y1 + 1) * (w + 1) + (x1 + 1)] - s[y0 * (w + 1) + (x1 + 1)]
                - s[(y1 + 1) * (w + 1) + x0] + s[y0 * (w + 1) + x0]
        }
        var tile = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
            for x in 0..<w {
                let i = y * w + x
                guard rough[i] else { continue }
                let x0 = max(0, x - radius), x1 = min(w - 1, x + radius)
                let n = boxSum(sumN, x0, y0, x1, y1)
                let white = n > 0 ? boxSum(sumL, x0, y0, x1, y1) / n : 255
                tile[i] = Double(lum[i]) > white * 0.86
            }
        }

        // Every patch of non-tile pixels.
        struct Blob { var area = 0, minX = Int.max, minY = Int.max, maxX = 0, maxY = 0, edge = false }
        var seen = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where !tile[start] && !seen[start] {
            var b = Blob()
            seen[start] = true
            stack.append(start)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                b.area += 1
                b.minX = min(b.minX, x); b.maxX = max(b.maxX, x)
                b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { b.edge = true }
                if x > 0, !tile[p - 1], !seen[p - 1] { seen[p - 1] = true; stack.append(p - 1) }
                if x < w - 1, !tile[p + 1], !seen[p + 1] { seen[p + 1] = true; stack.append(p + 1) }
                if y > 0, !tile[p - w], !seen[p - w] { seen[p - w] = true; stack.append(p - w) }
                if y < h - 1, !tile[p + w], !seen[p + w] { seen[p + w] = true; stack.append(p + w) }
            }
            blobs.append(b)
        }

        // Round, enclosed patches.
        let minArea = max(6, (w * h) / 200_000)
        let round = blobs.filter { b in
            guard !b.edge, b.area >= minArea else { return false }
            let bw = Double(b.maxX - b.minX + 1), bh = Double(b.maxY - b.minY + 1)
            let aspect = max(bw, bh) / min(bw, bh)
            let fill = Double(b.area) / (bw * bh)
            return aspect <= 1.8 && fill >= 0.5 && fill <= 0.95
        }
        guard !round.isEmpty else { return Result(pips: []) }

        // Pips in one set are similar in size; drop specks and stray marks.
        let median = round.map(\.area).sorted()[round.count / 2]
        let pips = round.filter { Double($0.area) >= 0.25 * Double(median) && Double($0.area) <= 4 * Double(median) }

        return Result(pips: pips.map {
            CGRect(x: Double($0.minX) / Double(w), y: Double($0.minY) / Double(h),
                   width: Double($0.maxX - $0.minX + 1) / Double(w),
                   height: Double($0.maxY - $0.minY + 1) / Double(h))
        })
    }

    /// The brightness that best splits the photo into two groups (Otsu's method).
    private static func otsu(_ histogram: [Int], total: Int) -> Int {
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumB = 0.0, weightB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            weightB += histogram[t]
            if weightB == 0 { continue }
            let weightF = total - weightB
            if weightF == 0 { break }
            sumB += Double(t * histogram[t])
            let meanB = sumB / Double(weightB), meanF = (sum - sumB) / Double(weightF)
            let between = Double(weightB) * Double(weightF) * (meanB - meanF) * (meanB - meanF)
            if between > best { best = between; threshold = t }
        }
        return threshold
    }
}
