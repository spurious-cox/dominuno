import CoreGraphics
import Foundation

/// Finds the pips in a photo of dominoes lying face up, whatever the color of the tiles or the table.
///
/// A pip is a small, round patch that differs in color from the tile around it, so the finder does not
/// assume light tiles or dark pips. It tries pip-sized round patches at many sizes and keeps the ones that
/// are (1) round to within a few percent, even with a flaw or a bar attached, (2) clearly different from the
/// tile body just outside them, and (3) surrounded by one fairly uniform color. The pips in one set are the
/// same size, so the size shared by the most separate, high-contrast patches wins and the rest is texture.
enum PipCounter {
    struct Result {
        /// Each pip's bounding box, as fractions (0–1) of the photo's width and height.
        var pips: [CGRect]
        var count: Int { pips.count }
    }

    static func count(_ image: CGImage, maxSide: Int = 1400) -> Result {
        let found = find(image, maxSide: maxSide)
        let w = Double(found.w), h = Double(found.h)
        return Result(pips: found.pips.map {
            CGRect(x: ($0.x - $0.r) / w, y: ($0.y - $0.r) / h, width: 2 * $0.r / w, height: 2 * $0.r / h)
        })
    }

    private struct Pip { var x: Double; var y: Double; var r: Double }

    // Tuning, from tests on photos and drawn scenes of white, black, wood and colored tiles.
    private static let roundMin = 0.85      // how much of a circle a pip must fill
    private static let rayMin = 0.85        // share of directions in which a merged pip's edge must sit at its radius
    private static let ringMin = 0.6        // share of the surrounding ring that must be one color
    private static let insideMin = 45.0     // how far a pip's color must be from the tile body around it
    private static let contrastMin = 0.4    // weakest contrast kept, relative to the set's median
    private static let tolFactor = 0.4      // ring color tolerance, relative to a pip's contrast
    private static let rayHi = 1.3
    private static let dedupeDist = 1.7     // pips closer than this many radii are one pip

    private static func find(_ image: CGImage, maxSide: Int = 1400) -> (pips: [Pip], w: Int, h: Int) {
        let scale = min(1.0, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return ([], w, h) }
        let n = w * h
        var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for i in 0..<n { for c in 0..<3 { ch[c][i] = Float(rgba[4 * i + c]) } }
        // integral images
        let W = w + 1
        var integ = [[Double]](repeating: [Double](repeating: 0, count: W * (h + 1)), count: 3)
        for c in 0..<3 {
            for y in 0..<h {
                var row = 0.0
                for x in 0..<w {
                    row += Double(ch[c][y * w + x])
                    integ[c][(y + 1) * W + x + 1] = integ[c][y * W + x + 1] + row
                }
            }
        }
        func box(_ c: Int, _ cx: Int, _ cy: Int, _ half: Int) -> (Double, Double) {
            let x0 = max(0, cx - half), x1 = min(w - 1, cx + half), y0 = max(0, cy - half), y1 = min(h - 1, cy + half)
            let s = integ[c][(y1 + 1) * W + x1 + 1] - integ[c][y0 * W + x1 + 1] - integ[c][(y1 + 1) * W + x0] + integ[c][y0 * W + x0]
            return (s, Double((x1 - x0 + 1) * (y1 - y0 + 1)))
        }
        func color(_ cx: Int, _ cy: Int, _ half: Int) -> [Double] { (0..<3).map { let (s, a) = box($0, cx, cy, half); return s / a } }
        func ring(_ cx: Int, _ cy: Int, _ inner: Int, _ outer: Int) -> [Double] {
            (0..<3).map { let (so, ao) = box($0, cx, cy, outer); let (si, ai) = box($0, cx, cy, inner); return (so - si) / max(1, ao - ai) }
        }
        func dist(_ a: [Double], _ b: [Double]) -> Double { sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }) }

        // candidate radii
        var radii: [Double] = []
        var r = 3.0
        while r <= Double(min(w, h)) / 12 { radii.append(r); r *= 1.22 }

        struct Cand { var x: Int; var y: Int; var r: Double; var resp: Double }
        var cands: [Cand] = []
        for r in radii {
            let hc = max(1, Int(r * 0.7)), hi = max(2, Int(r * 1.45)), ho = max(3, Int(r * 2.1))
            let step = max(1, Int(r / 3))
            var resp = [Double](repeating: 0, count: w * h)
            var y = ho
            while y < h - ho {
                var x = ho
                while x < w - ho {
                    resp[y * w + x] = dist(color(x, y, hc), ring(x, y, hi, ho))
                    x += step
                }
                y += step
            }
            // non-max within this scale
            let nm = max(1, Int(r / Double(step)))
            var y2 = ho
            while y2 < h - ho {
                var x2 = ho
                while x2 < w - ho {
                    let v = resp[y2 * w + x2]
                    if v > 30 {
                        var isMax = true
                        outer: for dy in -nm...nm { for dx in -nm...nm {
                            let yy = y2 + dy * step, xx = x2 + dx * step
                            if yy >= 0, yy < h, xx >= 0, xx < w, resp[yy * w + xx] > v { isMax = false; break outer }
                        } }
                        if isMax { cands.append(Cand(x: x2, y: y2, r: r, resp: v)) }
                    }
                    x2 += step
                }
                y2 += step
            }
        }
        // validate by segmentation
        var accepted: [(Pip, Double)] = []
        for c in cands {
            let hc = max(1, Int(c.r * 0.7)), hi = max(2, Int(c.r * 1.45)), ho = max(3, Int(c.r * 2.1))
            let cc = color(c.x, c.y, hc), rc = ring(c.x, c.y, hi, ho)
            let win = Int(c.r * 2.0)
            let x0 = max(0, c.x - win), x1 = min(w - 1, c.x + win), y0 = max(0, c.y - win), y1 = min(h - 1, c.y + win)
            let ww = x1 - x0 + 1, wh = y1 - y0 + 1
            // Pixels closer to the pip's color than to its surroundings.
            var mask = [Bool](repeating: false, count: ww * wh)
            for y in 0..<wh { for x in 0..<ww {
                let i = (y + y0) * w + (x + x0)
                let p = [Double(ch[0][i]), Double(ch[1][i]), Double(ch[2][i])]
                mask[y * ww + x] = dist(p, cc) < dist(p, rc)
            } }
            let e = max(1, Int(c.r * 0.4))
            func morph(_ m: [Bool], erode: Bool, e: Int) -> [Bool] {
                var I = [Int](repeating: 0, count: (ww + 1) * (wh + 1))
                for y in 0..<wh { var row = 0; for x in 0..<ww { row += m[y * ww + x] ? 1 : 0; I[(y + 1) * (ww + 1) + x + 1] = I[y * (ww + 1) + x + 1] + row } }
                var out = [Bool](repeating: false, count: ww * wh)
                for y in 0..<wh { for x in 0..<ww {
                    let xa = max(0, x - e), xb = min(ww - 1, x + e), ya = max(0, y - e), yb = min(wh - 1, y + e)
                    let cnt = I[(yb + 1) * (ww + 1) + xb + 1] - I[ya * (ww + 1) + xb + 1] - I[(yb + 1) * (ww + 1) + xa] + I[ya * (ww + 1) + xa]
                    let full = (xb - xa + 1) * (yb - ya + 1)
                    out[y * ww + x] = erode ? (cnt == full && x - e >= 0 && x + e < ww && y - e >= 0 && y + e < wh) : cnt > 0
                } }
                return out
            }
            let eC = max(1, Int(c.r * 0.18))
            mask = morph(morph(mask, erode: false, e: eC), erode: true, e: eC)
            // Fill holes first: a domed pip has shaded areas that look like its surroundings.
            do {
                var outside = [Bool](repeating: false, count: ww * wh)
                var st: [Int] = []
                for x in 0..<ww { for y in [0, wh - 1] { let k = y * ww + x; if !mask[k], !outside[k] { outside[k] = true; st.append(k) } } }
                for y in 0..<wh { for x in [0, ww - 1] { let k = y * ww + x; if !mask[k], !outside[k] { outside[k] = true; st.append(k) } } }
                while let k = st.popLast() {
                    let x = k % ww, y = k / ww
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || nx >= ww || ny < 0 || ny >= wh { continue }
                        let kk = ny * ww + nx
                        if !mask[kk], !outside[kk] { outside[kk] = true; st.append(kk) }
                    }
                }
                for k in 0..<(ww * wh) { mask[k] = !outside[k] }
            }
            // Opening removes thin attachments (the bar next to a pip, a glint) before the pip is traced.
            let opened = morph(morph(mask, erode: true, e: e), erode: false, e: e)
            let sx0 = c.x - x0, sy0 = c.y - y0
            guard opened[sy0 * ww + sx0] else { continue }
            var inBlob = [Bool](repeating: false, count: ww * wh)
            var stack = [(sx0, sy0)]
            inBlob[sy0 * ww + sx0] = true
            var touches = false
            while let (x, y) = stack.popLast() {
                if x == 0 || x == ww - 1 || y == 0 || y == wh - 1 { touches = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || nx >= ww || ny < 0 || ny >= wh { continue }
                    let k = ny * ww + nx
                    if !inBlob[k], opened[k] { inBlob[k] = true; stack.append((nx, ny)) }
                }
            }
            // Fill holes (a domed pip has shaded areas that look like the surroundings).
            var outside = [Bool](repeating: false, count: ww * wh)
            var st: [Int] = []
            for x in 0..<ww { for y in [0, wh - 1] { let k = y * ww + x; if !inBlob[k], !outside[k] { outside[k] = true; st.append(k) } } }
            for y in 0..<wh { for x in [0, ww - 1] { let k = y * ww + x; if !inBlob[k], !outside[k] { outside[k] = true; st.append(k) } } }
            while let k = st.popLast() {
                let x = k % ww, y = k / ww
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || nx >= ww || ny < 0 || ny >= wh { continue }
                    let kk = ny * ww + nx
                    if !inBlob[kk], !outside[kk] { outside[kk] = true; st.append(kk) }
                }
            }
            var area = 0, sx = 0.0, sy = 0.0
            for k in 0..<(ww * wh) where !outside[k] { area += 1; sx += Double(k % ww); sy += Double(k / ww) }
            guard area >= 6 else { continue }
            // Path 1: the whole traced shape is a circle.
            var founds: [Pip] = []
            if !touches {
                let ccx = sx / Double(area), ccy = sy / Double(area)
                let cr = (Double(area) / Double.pi).squareRoot()
                var inter = 0, uni = 0
                for y in 0..<wh { for x in 0..<ww {
                    let inC = hypot(Double(x) - ccx, Double(y) - ccy) <= cr
                    let inB = !outside[y * ww + x]
                    if inC && inB { inter += 1 }
                    if inC || inB { uni += 1 }
                } }
                if Double(inter) / Double(max(1, uni)) >= roundMin, cr >= 0.6 * c.r, cr <= 1.5 * c.r {
                    founds.append(Pip(x: ccx + Double(x0), y: ccy + Double(y0), r: cr))
                }
            }
            // Path 2: a pip with something attached (the bar beside it, a glint). The largest circle
            // that fits inside the shape is the pip; it must be pip-sized and the shape not much bigger.
            if founds.isEmpty {
                var dt = [Float](repeating: 0, count: ww * wh)
                let big: Float = 1e6
                for k in 0..<(ww * wh) { dt[k] = outside[k] ? 0 : big }
                for y in 0..<wh { for x in 0..<ww {
                    let k = y * ww + x
                    if dt[k] == 0 { continue }
                    if x == 0 || y == 0 { dt[k] = 1; continue }
                    dt[k] = min(dt[k], dt[k - 1] + 1, dt[k - ww] + 1, dt[k - ww - 1] + 1.414, (x + 1 < ww ? dt[k - ww + 1] + 1.414 : big))
                } }
                for y in stride(from: wh - 1, through: 0, by: -1) { for x in stride(from: ww - 1, through: 0, by: -1) {
                    let k = y * ww + x
                    if dt[k] == 0 { continue }
                    if x == ww - 1 || y == wh - 1 { dt[k] = 1; continue }
                    dt[k] = min(dt[k], dt[k + 1] + 1, dt[k + ww] + 1, dt[k + ww + 1] + 1.414, (x > 0 ? dt[k + ww - 1] + 1.414 : big))
                } }
                var firstPeak: Float = 0
                for _ in 0..<4 {
                    var pk = 0, pv: Float = 0
                    for k in 0..<(ww * wh) where dt[k] > pv { pv = dt[k]; pk = k }
                    if firstPeak == 0 { firstPeak = pv }
                    if pv < 0.8 * firstPeak { break }
                    let R = Double(pv) + 0.5
                    let px = Double(pk % ww), py = Double(pk / ww)
                    // clear this pip (and a margin) so the next-best peak is a different pip
                    for y in 0..<wh { for x in 0..<ww where hypot(Double(x) - px, Double(y) - py) <= 1.5 * R { dt[y * ww + x] = 0 } }
                    guard R >= 0.75 * c.r, R <= 1.3 * c.r else { continue }
                    // Rays from the center must leave the shape at about the pip's radius in nearly every
                    // direction; the few that run on (along a bar, into a flaw, into the pip beside it)
                    // are the tolerated exceptions.
                    var good = 0
                    let rays = 36
                    for k in 0..<rays {
                        let a = 2 * Double.pi * Double(k) / Double(rays)
                        var d = 0.0
                        while d < 2.0 * R {
                            let x = Int((px + cos(a) * d).rounded()), y = Int((py + sin(a) * d).rounded())
                            if x < 0 || y < 0 || x >= ww || y >= wh || outside[y * ww + x] { break }
                            d += 0.5
                        }
                        if d >= 0.8 * R, d <= rayHi * R { good += 1 }
                    }
                    if Double(good) / Double(rays) >= rayMin { founds.append(Pip(x: px + Double(x0), y: py + Double(y0), r: R)) }
                }
            }
            for f in founds { accepted.append((f, c.resp)) }
        }
        // A pip sits inside a tile: the ring just outside it is one fairly uniform color. A dark corner
        // or a gap at a tile's edge has tile on one side and table on the other.
        func enclosed(_ p: Pip, _ resp: Double) -> Bool {
            var samples: [[Double]] = []
            for rr in [1.5, 1.9] {
                for k in 0..<16 {
                    let a = 2 * Double.pi * Double(k) / 16
                    let x = Int((p.x + cos(a) * p.r * rr).rounded()), y = Int((p.y + sin(a) * p.r * rr).rounded())
                    if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 { return false }
                    samples.append(color(x, y, 1))
                }
            }
            let med = (0..<3).map { c in samples.map { $0[c] }.sorted()[samples.count / 2] }
            let tol = max(30.0, tolFactor * resp)
            // The pip itself must differ from the tile around it (a gap between pips is tile-colored inside).
            let px = Int(p.x.rounded()), py = Int(p.y.rounded())
            guard px >= 2, py >= 2, px < w - 2, py < h - 2 else { return false }
            let inside = color(px, py, max(1, Int(p.r * 0.5)))
            // The tile body right around the pip: a real pip differs clearly from it.
            var near: [[Double]] = []
            for rr in [1.25, 1.5] { for k in 0..<16 {
                let a = 2 * Double.pi * Double(k) / 16
                let x = Int((p.x + cos(a) * p.r * rr).rounded()), y = Int((p.y + sin(a) * p.r * rr).rounded())
                if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 { return false }
                near.append(color(x, y, 1))
            } }
            let nearMed = (0..<3).map { c in near.map { $0[c] }.sorted()[near.count / 2] }
            if dist(inside, nearMed) < insideMin { return false }
            return Double(samples.filter { dist($0, med) <= tol }.count) / Double(samples.count) >= ringMin
        }
        accepted = accepted.filter { enclosed($0.0, $0.1) }
        // merge duplicates across scales: strongest first
        accepted.sort { $0.1 > $1.1 }
        func dedupe(_ list: [(Pip, Double)]) -> [(Pip, Double)] {
            var kept: [(Pip, Double)] = []
            for e in list where !kept.contains(where: { hypot($0.0.x - e.0.x, $0.0.y - e.0.y) < dedupeDist * max($0.0.r, e.0.r) }) { kept.append(e) }
            return kept
        }
        // Pips in one set are the same size and contrast strongly with the tile. The size class holding
        // the most contrast (sum of squared contrast over its separate pips) is the pips; the rest is texture.
        var best: [(Pip, Double)] = []
        var bestScore = 0.0
        for (p, _) in accepted {
            let members = dedupe(accepted.filter { $0.0.r >= 0.87 * p.r && $0.0.r <= 1.15 * p.r })
            let score = members.reduce(0.0) { $0 + $1.1 * $1.1 }
            if score > bestScore { bestScore = score; best = members }
        }
        guard !best.isEmpty else { return ([], w, h) }
        let med = best.map(\.1).sorted()[best.count / 2]
        let core = best.filter { $0.1 >= contrastMin * med }
        // Pips whose outline merged with a neighbor measure a little larger; keep those that fit the set.
        let m = core.map { $0.0.r }.sorted()[core.count / 2]
        let extras = accepted.filter { $0.0.r >= 0.8 * m && $0.0.r <= 1.25 * m && $0.1 >= contrastMin * med }
        return (dedupe(core + extras).map(\.0), w, h)
    }
}
