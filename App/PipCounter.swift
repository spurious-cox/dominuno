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

    /// `tileAt` is a point on a tile body (fractions of the photo, origin top left); when given, its color is the
    /// tile color and every pip must sit on that color.
    static func count(_ image: CGImage, maxSide: Int = 1400, tileAt: CGPoint? = nil, tileColor: [Double]? = nil) -> Result {
        let found = find(image, maxSide: maxSide, tileAt: tileAt, tileColor: tileColor)
        let w = Double(found.w), h = Double(found.h)
        return Result(pips: found.pips.map {
            CGRect(x: ($0.x - $0.r) / w, y: ($0.y - $0.r) / h, width: 2 * $0.r / w, height: 2 * $0.r / h)
        })
    }

    /// Test hook: every pip-shaped candidate that passed the shape and on-tile tests (normalized rects), for layout matching.
    /// Test hook: the last count found tiles of several colors, so no single tile color was used.
    nonisolated(unsafe) static var multicolor = false
    nonisolated(unsafe) static var poolRects: [CGRect] = []
    /// Test hook: strong color-response blobs of pip size, whatever their traced shape (normalized rects), as extra layout evidence.
    nonisolated(unsafe) static var blobRects: [CGRect] = []
    private static let barLum = env("BARLUM", 0.45), barSat = env("BARSAT", 0.35), barFrac = env("BARFRAC", 0.12), barFracSmall = env("BARSMALLF", 0.04), smallPip = env("SMALLPIP", 0.85)
    private struct Pip { var x: Double; var y: Double; var r: Double }

    // Tuning, from tests on photos and drawn scenes of white, black, wood and colored tiles.
    private static let roundMin = 0.85      // how much of a circle a pip must fill
    private static let rayMin = 0.85        // share of directions in which a merged pip's edge must sit at its radius
    private static let ringMin = 0.6        // share of the surrounding ring that must be one color
    private static let insideMin = 45.0     // how far a pip's color must be from the tile body around it
    private static let contrastMin = env("CMIN", 0.2)    // weakest contrast kept, relative to the set's median
    private static let tolFactor = 0.4      // ring color tolerance, relative to a pip's contrast
    private static let rayHi = 1.3
    private static func env(_ k: String, _ d: Double) -> Double { Double(ProcessInfo.processInfo.environment[k] ?? "") ?? d }
    private static let edgeFrac = env("EDGE", 0.78)     // share of the pixels hugging a pip that must be tile-colored
    private static let ringFrac = env("RINGF", 0.7)     // share of the surrounding ring that must be tile-colored
    private static let tileTol = env("TILETOL", 80)     // color distance that still counts as tile-colored (tapped color)
    private static let ringRecover = env("RINGR", 0.7)    // share of the ring around a recovered pip that must be tile-colored
    private static let ringLoose = env("RINGL", 0.5)  // for a pip the size of the set, an engraved ring around it may darken part of its surround
    private static let edgeLoose = env("EDGEL", 0.78)
    private static let ringContrast = env("RC", 45)   // how far the engraved ring's color is from the tile
    private static let ringClosed = env("RCL", 0.85)   // share of directions in which that ring is present
    private static let barTol = env("BT", 60)   // color distance within which a run still counts as the same color
    private static let barRun = env("BR", 1.8)   // run length, in pip radii, that marks a bar or gap
    private static let sizeLo = env("SLO", 0)
    private static let sizeHi = env("SHI", 99)
    private static let outlierCost = env("OUTC", 3.0)
    private static let shadowSat = env("SSAT", 0.18)   // a shadowed tile face is still neutral: (max-min)/max below this
    private static let shadowLum = env("SLUM", 0.45)   // and at least this fraction of the tile's usual brightness
    private static let shadowTol = env("STOL", 50)
    private static let recoverSize = env("RSZ", 0.12)
    private static let blobMinResp = env("BMR", 90)
    private static let relaxedRoundMin = env("RELAX", 0.7) // looser roundness, used only for pips that match the set and sit on the tile
    private static let multiFrac = env("MULTIF", 0.25)  // share of pips on one tile color below which tiles count as multicolored
    private static let relaxNear = env("RELAXN", 6)
    private static let ghostNear = env("GHOSTN", 1.6), ghostNear2 = env("GHOSTN2", 2.05), overlapDist = env("OVLP", 2.1), ghostRatio = env("GHOSTR", 1.4)
    private static let dedupeDist = 1.7     // pips closer than this many radii are one pip

    private static func find(_ image: CGImage, maxSide: Int = 1400, tileAt: CGPoint? = nil, tileColor: [Double]? = nil) -> (pips: [Pip], w: Int, h: Int) {
        multicolor = false
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
        // DEBUG (test copy only): fate of candidates near the six unmarked gray pips of p17, written to
        // pipdebug.txt in the app's temp folder. Coordinates are in the analyzed (<=1400 px) image.
        let dbgTargets: [(Double, Double)] = env("DBGR",0)>0 ? [(338*Double(w)/1480, 855*Double(h)/1082), (358*Double(w)/1480, 900*Double(h)/1082), (388*Double(w)/1480, 945*Double(h)/1082)] : [(500, 455), (558, 451), (484, 484), (468, 512), (511, 535), (554, 558)]
        var dbgLog: [String] = ["image \(w)x\(h)"]
        func dbg(_ x: Double, _ y: Double, _ m: String) {
            for t in dbgTargets where hypot(t.0 - x, t.1 - y) < 22 { dbgLog.append(String(format: "(%.0f,%.0f) ", x, y) + m); break }
        }
        defer { try? dbgLog.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "pipdebug.txt", atomically: true, encoding: .utf8) }
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
                        if isMax { cands.append(Cand(x: x2, y: y2, r: r, resp: v)); dbg(Double(x2), Double(y2), String(format: "cand r=%.1f resp=%.0f", r, v)) }
                    }
                    x2 += step
                }
                y2 += step
            }
        }
        // validate by segmentation
        var accepted: [(Pip, Double)] = []
        var relaxed: [(Pip, Double)] = []   // pip-sized, 70–85% round: kept only if they fit the set (see below)
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
            guard opened[sy0 * ww + sx0] else { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f reject: center not in opened mask", c.r)); continue }
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
            guard area >= 6 else { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f reject: area %d < 6", c.r, area)); continue }
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
                if c.r >= 7 { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f path1: iou %.2f (min %.2f) shapeR %.1f", c.r, Double(inter) / Double(max(1, uni)), roundMin, cr)) }
                let iou = Double(inter) / Double(max(1, uni))
                if iou >= roundMin, cr >= 0.6 * c.r, cr <= 1.5 * c.r {
                    founds.append(Pip(x: ccx + Double(x0), y: ccy + Double(y0), r: cr))
                } else if iou >= relaxedRoundMin, cr >= 0.8 * c.r, cr <= 1.25 * c.r {
                    relaxed.append((Pip(x: ccx + Double(x0), y: ccy + Double(y0), r: cr), c.resp))
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
                    if c.r >= 7 { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f path2: peak R %.1f (allowed %.1f..%.1f)", c.r, R, 0.75 * c.r, 1.3 * c.r)) }
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
                    if c.r >= 7 { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f path2: rays %d/%d (min %.2f)", c.r, good, rays, rayMin)) }
                    if Double(good) / Double(rays) >= rayMin { founds.append(Pip(x: px + Double(x0), y: py + Double(y0), r: R)) }
                }
            }
            if founds.isEmpty { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f reject: not round or wrong size (touches=%d area=%d)", c.r, touches ? 1 : 0, area)) }
            else { dbg(Double(c.x), Double(c.y), String(format: "r=%.1f shape ok", c.r)) }
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
            if dist(inside, nearMed) < insideMin { dbg(p.x, p.y, String(format: "r=%.1f enclosed: inside vs near color dist %.0f < %.0f", p.r, dist(inside, nearMed), insideMin)); return false }
            let frac = Double(samples.filter { dist($0, med) <= tol }.count) / Double(samples.count)
            if frac < ringMin { dbg(p.x, p.y, String(format: "r=%.1f enclosed: ring uniformity %.2f < %.2f (tol %.0f)", p.r, frac, ringMin, tol)) }
            return frac >= ringMin
        }
        accepted = accepted.filter { enclosed($0.0, $0.1) }
        relaxed = relaxed.filter { enclosed($0.0, $0.1) }
        // merge duplicates across scales: strongest first
        accepted.sort { $0.1 > $1.1 }
        func dedupe(_ list: [(Pip, Double)]) -> [(Pip, Double)] {
            var kept: [(Pip, Double)] = []
            for e in list where !kept.contains(where: { hypot($0.0.x - e.0.x, $0.0.y - e.0.y) < dedupeDist * max($0.0.r, e.0.r) }) { kept.append(e) }
            return kept
        }
        // Pips in one set are the same size and contrast strongly with the tile. The size class holding
        // the most contrast (sum of squared contrast over its separate pips) is the pips; the rest is texture.
        // A photo can hold more than one pip size (large pips on low halves, small on 9–12), so after the
        // strongest class is taken, further classes are taken from what is left if numerous and contrasty.
        var result: [Pip] = []
        var pool = accepted
        var firstScore = 0.0
        var firstR = 0.0
        for round in 0..<4 {
            var best: [(Pip, Double)] = []
            var bestScore = 0.0
            for (p, _) in pool {
                let members = dedupe(pool.filter { $0.0.r >= 0.87 * p.r && $0.0.r <= 1.15 * p.r })
                let score = members.reduce(0.0) { $0 + $1.1 * $1.1 }
                if score > bestScore { bestScore = score; best = members }
            }
            if best.isEmpty { break }
            if round == 0 { firstScore = bestScore; firstR = best.map { $0.0.r }.sorted()[best.count / 2] }
            else if best.map({ $0.0.r }).sorted()[best.count / 2] < 0.5 * firstR { break }
            else if bestScore < env("CLS", 0.1) * firstScore || best.count < 3 { break }
            let med = best.map(\.1).sorted()[best.count / 2]
            let core = best.filter { $0.1 >= contrastMin * med }
            // Pips whose outline merged with a neighbor measure a little larger; keep those that fit the set.
            let m = core.map { $0.0.r }.sorted()[core.count / 2]
            let extras = pool.filter { $0.0.r >= 0.8 * m && $0.0.r <= 1.25 * m && $0.1 >= contrastMin * med }
            let cls = dedupe(core + extras)
            // Drop what overlaps pips already kept in another size class.
            let fresh = cls.filter { c in !result.contains { hypot($0.x - c.0.x, $0.y - c.0.y) < 1.2 * max($0.r, c.0.r) } }
            result += fresh.map(\.0)
            pool = pool.filter { e in !cls.contains { hypot($0.0.x - e.0.x, $0.0.y - e.0.y) < dedupeDist * max($0.0.r, e.0.r) } }
        }
        // The tile body color: the one the user tapped (median of a small window, so a pip under the tap
        // cannot skew it), else the median color around the pips found. A pip sits on the tile: the ring
        // around it is mostly tile-colored (not table, mat or a divider bar) and its own color is not.
        func around(_ p: Pip) -> [[Double]]? {
            var s: [[Double]] = []
            for rr in [1.5, 1.9] { for k in 0..<16 {
                let a = 2 * Double.pi * Double(k) / 16
                let x = Int((p.x + cos(a) * p.r * rr).rounded()), y = Int((p.y + sin(a) * p.r * rr).rounded())
                if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 { return nil }
                s.append(color(x, y, 1))
            } }
            return s
        }
        func median(_ v: [[Double]]) -> [Double] { (0..<3).map { c in v.map { $0[c] }.sorted()[v.count / 2] } }
        var body: [Double]? = nil
        var tol = 45.0
        if let tc = tileColor {
            body = tc; tol = tileTol
        } else if let t = tileAt {
            let tx = Int(t.x * Double(w)), ty = Int(t.y * Double(h))
            var samples: [[Double]] = []
            for dy in stride(from: -12, through: 12, by: 3) { for dx in stride(from: -12, through: 12, by: 3) {
                let x = tx + dx, y = ty + dy
                if x >= 1, y >= 1, x < w - 1, y < h - 1 { samples.append(color(x, y, 1)) }
            } }
            if !samples.isEmpty { body = median(samples); tol = tileTol }
        } else if result.count >= 4 {
            let rings = result.compactMap(around).map(median)
            if rings.count >= 4 { body = median(rings) }
        }
        // Multicolored tiles: when most pips do not sit on one shared tile color, there is no single body color to
        // test against. Each pip was already checked against its own uniform surround, so keep them as found.
        if let b = body, tileColor == nil, tileAt == nil, result.count >= 4 {
            let onBody = result.compactMap(around).map(median).filter { dist($0, b) < tol }.count
            if env("DBGN",0)>0 { FileHandle.standardError.write(Data("onBody=\(onBody)/\(result.count) tol=\(tol)\n".utf8)) }
            if Double(onBody) / Double(result.count) < multiFrac { body = nil; multicolor = true }
        }
        if env("DBGN",0)>0 { FileHandle.standardError.write(Data("cands=\(cands.count) accepted=\(accepted.count) relaxed=\(relaxed.count) class=\(result.count) body=\(String(describing: body))\n".utf8)) }
        if env("DBGR",0)>0 {
            let dbgBox = (ProcessInfo.processInfo.environment["DBGBOX"] ?? "0,9999,0,9999").split(separator: ",").compactMap { Double($0) }
            let k = Double(w) / 1480
            for (p, c) in accepted.sorted(by: { $0.1 > $1.1 }) where p.x/k > dbgBox[0] && p.x/k < dbgBox[1] && p.y/k > dbgBox[2] && p.y/k < dbgBox[3] { FileHandle.standardError.write(Data(String(format: "acc (%.0f,%.0f) r=%.1f resp=%.0f inClass=%d\n", p.x/k, p.y/k, p.r, c, result.contains { hypot($0.x-p.x,$0.y-p.y) < p.r } ? 1 : 0).utf8)) }
            FileHandle.standardError.write(Data("firstR=\(firstR) classes=\(result.count)\n".utf8))
        }
        var base: [Pip] = []
        if let body {
            func onTile(_ p: Pip, ringReq: Double = ringFrac, edgeReq: Double = edgeFrac, checkInside: Bool = true) -> Bool {
                let px = Int(p.x.rounded()), py = Int(p.y.rounded())
                guard px >= 2, py >= 2, px < w - 2, py < h - 2 else { return true }
                if checkInside, dist(color(px, py, max(1, Int(p.r * 0.5))), body) < insideMin { return false }
                guard let ring = around(p) else { return false }
                // The tile face can be darker than the typical tile (shadow, vignette). A pip counts as on the tile when its
                // own surround is the tile color, or a uniform, neutral (unsaturated), fairly bright surface: a shadowed face.
                var ref = body, refTol = tol
                if Double(ring.filter { dist($0, body) < tol }.count) / Double(ring.count) < ringReq {
                    let rm = median(ring)
                    let hi = rm.max()!, lo = rm.min()!
                    let lumR = 0.3 * rm[0] + 0.59 * rm[1] + 0.11 * rm[2]
                    let lumB = 0.3 * body[0] + 0.59 * body[1] + 0.11 * body[2]
                    let neutral = hi > 0 && (hi - lo) / hi < shadowSat
                    let uniform = Double(ring.filter { dist($0, rm) < shadowTol }.count) / Double(ring.count) >= 0.8
                    guard neutral, uniform, lumR > shadowLum * lumB, dist(color(px, py, max(1, Int(p.r * 0.5))), rm) >= insideMin else { return false }
                    ref = rm; refTol = shadowTol
                }
                // The edge right around the pip is all tile: a dot on a divider bar or a tile edge has dark
                // (or table-colored) pixels touching it on two sides.
                var close = 0, total = 0
                for k in 0..<24 {
                    let a = 2 * Double.pi * Double(k) / 24
                    let x = Int((p.x + cos(a) * p.r * 1.3).rounded()), y = Int((p.y + sin(a) * p.r * 1.3).rounded())
                    guard x >= 1, y >= 1, x < w - 1, y < h - 1 else { return false }
                    total += 1
                    if dist(color(x, y, 1), ref) < refTol { close += 1 }
                }
                return Double(close) / Double(total) >= edgeFrac
            }
            result = result.filter { onTile($0) }
            base = result
            // A pip inside a pattern of kept pips (at least 3 within 5 radii, so it is on the same tile) whose own color
            // differs from the tile. Its surrounding ring is not tested: it reaches the neighboring pips.
            func crowded(_ p: Pip, within: Double = 5, atLeast: Int = 3) -> Bool {
                let px = Int(p.x.rounded()), py = Int(p.y.rounded())
                guard px >= 2, py >= 2, px < w - 2, py < h - 2 else { return false }
                if dist(color(px, py, max(1, Int(p.r * 0.5))), body) < insideMin { return false }
                return result.filter { hypot($0.x - p.x, $0.y - p.y) < within * p.r }.count >= atLeast
            }
            // A pip that passed every check but was crowded out of its size class (a duplicate trace at another
            // scale won) is put back when no kept pip is on it and it is the size of the kept pips.
            let tapless = env("NOISO", 0) > 0
            var recovered: [Pip] = []
            // An engraved ring pip: its middle is the tile's own color, and a closed ring of different color runs
            // around it at about its radius (every direction, not just a bar or a gap edge on one side).
            func engraved(_ p: Pip) -> Bool {
                let px = Int(p.x.rounded()), py = Int(p.y.rounded())
                guard px >= 2, py >= 2, px < w - 2, py < h - 2 else { return false }
                if dist(color(px, py, max(1, Int(p.r * 0.4))), body) >= insideMin { return false }
                var hits = 0
                for k in 0..<24 {
                    let a = 2 * Double.pi * Double(k) / 24
                    var far = 0.0
                    for f in stride(from: 0.7, through: 1.2, by: 0.1) {
                        let x = Int((p.x + cos(a) * p.r * f).rounded()), y = Int((p.y + sin(a) * p.r * f).rounded())
                        guard x >= 1, y >= 1, x < w - 1, y < h - 1 else { return false }
                        far = max(far, dist(color(x, y, 1), body))
                    }
                    if far >= ringContrast { hits += 1 }
                }
                return Double(hits) / 24 >= ringClosed
            }
            if !result.isEmpty {
                let rs = result.map(\.r).sorted()
                let mr = rs[rs.count / 2]
                for (p, _) in dedupe(accepted.sorted { $0.1 > $1.1 }) {
                    guard p.r >= 0.75 * mr, p.r <= 2.0 * mr,
                          !result.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 1.2 * max($0.r, p.r) }),
                          crowded(p) || (abs(p.r - mr) <= recoverSize * mr && engraved(p) && onTile(p, ringReq: ringLoose, edgeReq: edgeLoose, checkInside: false) && !tapless) else { continue }
                    result.append(Pip(x: p.x, y: p.y, r: min(p.r, 1.1 * mr)))
                    recovered.append(Pip(x: p.x, y: p.y, r: p.r))
                }
            }
            // Pips that are a little less round (low-contrast gray pips are traced raggedly) count when
            // they are the size of pips already found, sit on the tile and do not overlap a found pip.
            let radii = result.map(\.r)
            for (p, _) in dedupe(relaxed.sorted { $0.1 > $1.1 }) {
                guard radii.contains(where: { p.r >= 0.8 * $0 && p.r <= 1.25 * $0 }),
                      !result.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 1.2 * max($0.r, p.r) }),
                      onTile(p) else { continue }
                result.append(p)
            }
            // Low-contrast pips (dark red on a black tile) have an irregular outline, so the shape test fails them.
            // One that is a strong local color response, is pip-sized, differs from the tile around it and sits in a
            // pattern of kept pips is still a pip.
            if result.count >= 6, env("NORESP", 0) == 0 {
                let rs = result.map(\.r).sorted()
                let mr = rs[rs.count / 2]
                for c in cands.sorted(by: { $0.resp > $1.resp }) where c.r >= env("RLO", 0.7) * mr && c.r <= env("RHI", 1.4) * mr && c.resp >= 40 {
                    let p = Pip(x: Double(c.x), y: Double(c.y), r: c.r)
                    guard !result.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 1.2 * max($0.r, p.r) }),
                          crowded(p, within: 7, atLeast: 2) else { continue }
                    // It is the color of the pips beside it (not a bar, a rim or a gap).
                    let mine = color(c.x, c.y, max(1, Int(c.r * 0.5)))
                    let near = result.filter { hypot($0.x - p.x, $0.y - p.y) < 5 * p.r }
                    guard near.contains(where: { dist(mine, color(Int($0.x.rounded()), Int($0.y.rounded()), max(1, Int($0.r * 0.5)))) < 35 }) else { continue }
                    // The ring right around it is mostly tile (neighboring pips and bars take part of it).
                    var close = 0, total = 0
                    for k in 0..<24 {
                        let a = 2 * Double.pi * Double(k) / 24
                        let x = Int((p.x + cos(a) * p.r * 1.25).rounded()), y = Int((p.y + sin(a) * p.r * 1.25).rounded())
                        total += 1
                        guard x >= 1, y >= 1, x < w - 1, y < h - 1 else { continue }
                        if dist(color(x, y, 1), body) < tol { close += 1 }
                    }
                    guard Double(close) / Double(total) >= ringRecover else { continue }
                    // A bar or a gap is the pip's color for a long way; a pip is color-different from the tile within a radius or two.
                    var run = 0.0
                    for k in 0..<16 {
                        let a = 2 * Double.pi * Double(k) / 16
                        var d = c.r * 0.5
                        while d < 6 * c.r {
                            let x = Int((p.x + cos(a) * d).rounded()), y = Int((p.y + sin(a) * d).rounded())
                            guard x >= 1, y >= 1, x < w - 1, y < h - 1, dist(color(x, y, 1), mine) < barTol else { break }
                            d += 1
                        }
                        run = max(run, d)
                    }
                    guard run < barRun * c.r else { continue }
                    result.append(p)
                }
            }
            // A small cluster (fewer than 3 pips within 10 radii of one another) must sit on a clean tile-colored ring:
            // a speck on a light mat is near the tile color, but not as near as the tile around a real pip.
            func clusterSize(_ p: Pip) -> Int {
                var seen: Set<Int> = []
                var stack = [result.firstIndex(where: { $0.x == p.x && $0.y == p.y }) ?? 0]
                while let i = stack.popLast() {
                    if !seen.insert(i).inserted { continue }
                    for j in result.indices where !seen.contains(j) && hypot(result[i].x - result[j].x, result[i].y - result[j].y) < 10 * max(result[i].r, result[j].r) { stack.append(j) }
                }
                return seen.count
            }
            let snapshot = result
            result = snapshot.filter { p in
                result = snapshot
                if clusterSize(p) >= 3 || recovered.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 2 }) { return true }
                // A pip alone (or one of a pair) belongs to a tile whose other half has pips: a real tile is about
                // 20 pip radii long, so something far from every larger group is a speck, not a pip.
                let big = snapshot.filter { q in
                    q.x != p.x || q.y != p.y ? true : false
                }.filter { q in
                    snapshot.filter { hypot($0.x - q.x, $0.y - q.y) < 10 * q.r }.count >= 3
                }
                if !big.isEmpty && !big.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 22 * p.r }) { return false }
                // a pip differs from the tile; a gap between tiles or a speck of the tile's own color does not
                let px = Int(p.x.rounded()), py = Int(p.y.rounded())
                guard px >= 2, py >= 2, px < w - 2, py < h - 2, dist(color(px, py, max(1, Int(p.r * 0.5))), body) >= insideMin else { return false }
                guard let ring = around(p) else { return false }
                return Double(ring.filter { dist($0, body) < 45 }.count) / Double(ring.count) >= 0.85
            }
        }
        // Multicolored tiles: pips a little less round (domed, shaded) are kept when they are the size of at least two
        // other pips close by (the same half). Pip size is per half, so it is not compared with the whole photo.
        if body == nil, multicolor {
            for (p, _) in dedupe(relaxed.sorted { $0.1 > $1.1 }) {
                guard !result.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 1.2 * max($0.r, p.r) }) else { continue }
                let like = (result + relaxed.map(\.0)).filter { q in
                    (q.x != p.x || q.y != p.y) && hypot(q.x - p.x, q.y - p.y) < relaxNear * p.r && q.r >= 0.8 * p.r && q.r <= 1.25 * p.r
                }
                if like.count >= 2 { result.append(p) }
            }
        }
        for (p, c) in accepted where !result.contains(where: { hypot($0.x - p.x, $0.y - p.y) < p.r }) {
            dbg(p.x, p.y, String(format: "passed all checks but not in final: r=%.1f contrast=%.0f (class selection, overlap, or on-tile filter)", p.r, c))
        }
        for p in result { dbg(p.x, p.y, String(format: "FINAL kept r=%.1f", p.r)) }
        // A dot touching the dark divider bar is not a pip: dark, unsaturated pixels around it, on a bright tile.
        let medR: Double = { let rs = result.map(\.r).sorted(); return rs.isEmpty ? 0 : rs[rs.count / 2] }()
        func touchesBar(_ p: Pip) -> Bool {
            let frac = p.r < smallPip * medR ? barFracSmall : barFrac
            // Multicolored tiles have no single body color: use the color around this pip.
            guard let tileBody = body ?? around(p).map(median) else { return false }
            let lumB = 0.3 * tileBody[0] + 0.59 * tileBody[1] + 0.11 * tileBody[2]
            guard lumB > 120 else { return false }
            var dark = 0, total = 0
            for k in 0..<24 {
                let a = 2 * Double.pi * Double(k) / 24
                for f in [1.25, 1.6] {
                    let x = Int((p.x + cos(a) * p.r * f).rounded()), y = Int((p.y + sin(a) * p.r * f).rounded())
                    guard x >= 1, y >= 1, x < w - 1, y < h - 1 else { continue }
                    let c = color(x, y, 1)
                    let hi = c.max()!, lo = c.min()!
                    total += 1
                    if 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] < barLum * lumB, hi > 0 ? (hi - lo) / hi < barSat : true { dark += 1 }
                }
            }
            return total > 0 && Double(dark) / Double(total) >= frac
        }
        result = result.filter { !touchesBar($0) }
        // Pips do not overlap. A dot that overlaps another pip and is much weaker in contrast is a ghost between pips
        // (the midpoint of two real ones); the weaker of such a pair goes.
        if env("GHOSTALL", 1) > 0 || multicolor {
            func respOf(_ p: Pip) -> Double { max(accepted.filter { hypot($0.0.x - p.x, $0.0.y - p.y) < 0.6 * p.r }.map(\.1).max() ?? 0, cands.filter { hypot(Double($0.x) - p.x, Double($0.y) - p.y) < 0.6 * p.r && $0.r >= 0.7 * p.r && $0.r <= 1.4 * p.r }.map(\.resp).max() ?? 0) }
            let rs = Dictionary(uniqueKeysWithValues: result.indices.map { ($0, respOf(result[$0])) })
            var drop = Set<Int>()
            for i in result.indices { for j in result.indices where j > i {
                guard hypot(result[i].x - result[j].x, result[i].y - result[j].y) < overlapDist * min(result[i].r, result[j].r) else { continue }
                let a = rs[i] ?? 0, b = rs[j] ?? 0
                if a > 0, b > 0 { if a >= ghostRatio * b { drop.insert(j) } else if b >= ghostRatio * a { drop.insert(i) } }
            } }
            let gone = drop.map { result[$0] }
            result = result.indices.filter { !drop.contains($0) }.map { result[$0] }
            // keep the ghost out of the layout evidence as well
            accepted = accepted.filter { a in !gone.contains { hypot($0.x - a.0.x, $0.y - a.0.y) < 0.8 * $0.r } }
            relaxed = relaxed.filter { a in !gone.contains { hypot($0.x - a.0.x, $0.y - a.0.y) < 0.8 * $0.r } }
        }
        // Pips cannot overlap: a dot closer than 1.6 radii to two or more others is a ghost between them (a real pair
        // of touching pips is at least two radii apart). The dot with the most such neighbors goes first.
        if env("GHOST2", 1) > 0 {
            var gone: [Pip] = []
            while true {
                var worst = -1, most = 1
                for i in result.indices {
                    let n = result.indices.filter { $0 != i && hypot(result[i].x - result[$0].x, result[i].y - result[$0].y) < ghostNear * min(result[i].r, result[$0].r) }.count
                    // or three or more neighbors almost touching all round (the middle of a block of pips)
                    let n2 = result.indices.filter { $0 != i && hypot(result[i].x - result[$0].x, result[i].y - result[$0].y) < ghostNear2 * min(result[i].r, result[$0].r) }.count
                    let score = n >= 2 ? n + 10 : (n2 >= 3 ? n2 : 0)
                    if score > most { most = score; worst = i }
                }
                if worst < 0 { break }
                gone.append(result.remove(at: worst))
            }
            accepted = accepted.filter { a in !gone.contains { hypot($0.x - a.0.x, $0.y - a.0.y) < 0.8 * $0.r } }
            relaxed = relaxed.filter { a in !gone.contains { hypot($0.x - a.0.x, $0.y - a.0.y) < 0.8 * $0.r } }
        }
        // Pips in one photo are one size (perspective changes it a little): drop dots far from the median size.
        if result.count >= 8 {
            let rs = result.map(\.r).sorted()
            let mr = rs[rs.count / 2]
            result = result.filter { $0.r >= sizeLo * mr && $0.r <= sizeHi * mr }
        }
        do {
            let rs = (result.isEmpty ? accepted.map(\.0) : result).map(\.r).sorted()
            let mr = rs.isEmpty ? 0 : rs[rs.count / 2]
            var blobs: [Cand] = []
            for c in cands.sorted(by: { $0.resp > $1.resp }) where mr > 0 && !touchesBar(Pip(x: Double(c.x), y: Double(c.y), r: c.r)) && c.resp >= blobMinResp && c.r >= 0.7 * mr && c.r <= 1.5 * mr {
                if !blobs.contains(where: { hypot(Double($0.x - c.x), Double($0.y - c.y)) < 1.2 * max($0.r, c.r) }) { blobs.append(c) }
            }
            // a candidate that overlaps two or more found pips is a ghost between them, not extra layout evidence
            blobs = blobs.filter { c in result.filter { hypot($0.x - Double(c.x), $0.y - Double(c.y)) < ghostNear * min($0.r, c.r) }.count < 2 }
            blobRects = blobs.map { CGRect(x: (Double($0.x) - $0.r) / Double(w), y: (Double($0.y) - $0.r) / Double(h), width: 2 * $0.r / Double(w), height: 2 * $0.r / Double(h)) }
        }
        func ghostly(_ p: Pip) -> Bool { result.filter { $0.x != p.x || $0.y != p.y }.filter { hypot($0.x - p.x, $0.y - p.y) < ghostNear * min($0.r, p.r) }.count >= 2 }
        poolRects = (accepted.map(\.0) + relaxed.map(\.0)).filter { !ghostly($0) }.map { CGRect(x: ($0.x - $0.r) / Double(w), y: ($0.y - $0.r) / Double(h), width: 2 * $0.r / Double(w), height: 2 * $0.r / Double(h)) }
        if env("LAYOUT", 0) > 0, base.count >= 3 {
            var pool = result
            for (p, _) in accepted { pool.append(p) }
            for (p, _) in relaxed { pool.append(p) }
            result = layoutRefine(base: base, weak: pool)
        }
        if env("DBGR",0)>0 { let k = Double(w) / 1480; for p in result where p.x/k > 300 && p.x/k < 520 && p.y/k > 780 && p.y/k < 1010 { FileHandle.standardError.write(Data(String(format: "final (%.0f,%.0f) r=%.1f\n", p.x/k, p.y/k, p.r).utf8)) } }
        return (result, w, h)
    }

    // Standard half-tile layouts, normalized to the half square (y down).
    private static let layouts: [[(Double, Double)]] = {
        func grid(_ xs: [Double], _ ys: [Double]) -> [(Double, Double)] { var p: [(Double, Double)] = []; for y in ys { for x in xs { p.append((x, y)) } }; return p }
        var L: [[(Double, Double)]] = []
        L.append([(0.5, 0.5)])
        L.append([(0.27, 0.27), (0.73, 0.73)])
        L.append([(0.25, 0.25), (0.5, 0.5), (0.75, 0.75)])
        L.append(grid([0.27, 0.73], [0.27, 0.73]))
        L.append(grid([0.27, 0.73], [0.27, 0.73]) + [(0.5, 0.5)])
        L.append(grid([0.3, 0.7], [0.2, 0.5, 0.8]))
        L.append(grid([0.3, 0.7], [0.2, 0.5, 0.8]) + [(0.5, 0.5)])
        L.append(grid([0.22, 0.5, 0.78], [0.22, 0.5, 0.78]).filter { !($0.0 == 0.5 && $0.1 == 0.5) })
        L.append(grid([0.22, 0.5, 0.78], [0.22, 0.5, 0.78]))
        let x4 = [0.15, 0.38, 0.62, 0.85]
        L.append(grid(x4, [0.22]) + [(0.15, 0.5), (0.85, 0.5)] + grid(x4, [0.78]))
        L.append(grid(x4, [0.22]) + [(0.38, 0.5), (0.62, 0.5)] + grid(x4, [0.78]))
        L.append(grid(x4, [0.22]) + [(0.15, 0.5), (0.5, 0.5), (0.85, 0.5)] + grid(x4, [0.78]))
        L.append(grid(x4, [0.22]) + [(0.27, 0.5), (0.5, 0.5), (0.73, 0.5)] + grid(x4, [0.78]))
        L.append(grid(x4, [0.22, 0.5, 0.78]))
        return L
    }()

    /// Groups the confident pips into halves (pips of one half are close together) and fits each group to a standard
    /// layout at any angle. Weaker candidates are accepted where they fill a layout position the confident pips leave
    /// empty, and a confident pip that sits off the layout is dropped.
    private static func layoutRefine(base: [Pip], weak: [Pip]) -> [Pip] {
        let mr = base.map(\.r).sorted()[base.count / 2]
        let tol = 0.7 * mr
        // single-linkage groups
        var group = [Int](repeating: -1, count: base.count)
        var ng = 0
        for i in base.indices where group[i] < 0 {
            var st = [i]; group[i] = ng
            while let a = st.popLast() { for b in base.indices where group[b] < 0 && hypot(base[a].x - base[b].x, base[a].y - base[b].y) < 3.6 * mr { group[b] = ng; st.append(b) } }
            ng += 1
        }
        var out: [Pip] = []
        let scales: [Double] = [8, 9, 10, 11, 12, 13, 14].map { $0 }
        for g in 0..<ng {
            let pts = base.indices.filter { group[$0] == g }.map { base[$0] }
            // weak candidates near this group, not already confident pips
            let cx = pts.map(\.x).reduce(0, +) / Double(pts.count), cy = pts.map(\.y).reduce(0, +) / Double(pts.count)
            var cand: [Pip] = []
            for q in weak where hypot(q.x - cx, q.y - cy) < 12 * mr && !pts.contains(where: { hypot($0.x - q.x, $0.y - q.y) < 1.0 * mr }) {
                if !cand.contains(where: { hypot($0.x - q.x, $0.y - q.y) < 1.2 * mr }) { cand.append(q) }
            }
            var best: (cost: Double, keep: [Pip], add: [Pip])? = nil
            let a0 = pts[0]
            for lay in layouts {
                for mirror in [1.0, -1.0] {
                    for ai in 0..<60 {
                        let th = Double(ai) * Double.pi / 30
                        let c = cos(th), s = sin(th)
                        for sc in scales {
                            let L = sc * mr
                            // layout points in image coordinates relative to the half's center
                            let rel = lay.map { (u, v) -> (Double, Double) in
                                let x = mirror * (u - 0.5) * L, y = (v - 0.5) * L
                                return (c * x - s * y, s * x + c * y)
                            }
                            for j in rel.indices {
                                let ox = a0.x - rel[j].0, oy = a0.y - rel[j].1
                                var usedP = [Bool](repeating: false, count: pts.count)
                                var usedC = [Bool](repeating: false, count: cand.count)
                                var cost = 0.0
                                var adds: [Pip] = []
                                for q in rel {
                                    let qx = ox + q.0, qy = oy + q.1
                                    var bi = -1, bd = tol
                                    for (i, p) in pts.enumerated() where !usedP[i] { let d = hypot(p.x - qx, p.y - qy); if d < bd { bd = d; bi = i } }
                                    if bi >= 0 { usedP[bi] = true; continue }
                                    var ci = -1; bd = tol
                                    for (i, p) in cand.enumerated() where !usedC[i] { let d = hypot(p.x - qx, p.y - qy); if d < bd { bd = d; ci = i } }
                                    if ci >= 0 { usedC[ci] = true; cost += 0.15; adds.append(cand[ci]) } else { cost += 1.0 }
                                }
                                let outliers = usedP.filter { !$0 }.count
                                cost += outlierCost * Double(outliers)
                                if best == nil || cost < best!.cost - 1e-9 {
                                    best = (cost, pts.indices.filter { usedP[$0] }.map { pts[$0] }, adds)
                                }
                            }
                        }
                    }
                }
            }
            if let b = best, b.cost <= 1.35 { out += b.keep + b.add } else { out += pts }
        }
        return out
    }
}
