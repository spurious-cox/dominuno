import Foundation
import CoreGraphics

/// A tile found in a photo: center, long-axis direction (unit vector), length A and width B, all in the working image's pixels.
struct FoundTile { var cx, cy, ux, uy, A, B: Double; var area: Int }

/// Finds the tiles in a photo of dominoes from the pips already found, splits each into its two halves, and matches
/// every half to a standard pip layout (0–12).
enum TileHalves {
    struct Half {
        var tile: Int
        var index: Int
        var count: Int           // pips, after layout matching
        var raw: Int             // pips found before layout matching
        var center: CGPoint      // fractions of the photo (origin top left)
    }
    struct Result {
        var tiles: [FoundTile]
        var halves: [Half]
        var workW: Int, workH: Int
        var faceColor: [Double]? // median color of the tile faces, for a second, tile-color-aware pip pass
    }

    /// Test hook: the tile mask at the working size (pixels counted as tile face or pip), for drawing.
    nonisolated(unsafe) static var debugMask: (w: Int, h: Int, mask: [Bool]) = (0, 0, [])
    /// Test hooks: pips left out of every half count because they are not the size of the other pips in their half
    /// (centers, fractions of the photo), and the divider bars found (working-image pixels).
    nonisolated(unsafe) static var droppedPips: [CGPoint] = []
    /// Test hook: pips the layout match supplied that no pip was found for (image positions as fractions, with size).
    nonisolated(unsafe) static var layoutPips: [CGRect] = []
    nonisolated(unsafe) static var debugBars: [(cx: Double, cy: Double, dx: Double, dy: Double, len: Double, thick: Double)] = []
    static func analyze(_ img: CGImage, pips pipRects: [CGRect], pool poolRects: [CGRect], blobs blobRects: [CGRect] = [], faceOnly: Bool = false) -> Result {
droppedPips = []; debugBars = []; layoutPips = []
let W = img.width, H = img.height
// working copy, at most 800 px on the long side
let ws = min(1.0, 800.0 / Double(max(W, H)))
let w = Int(Double(W) * ws), h = Int(Double(H) * ws)
var rgba = [UInt8](repeating: 0, count: w * h * 4)
let c0 = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c0.interpolationQuality = .medium
c0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
func px(_ x: Int, _ y: Int) -> [Double] { let i = (y * w + x) * 4; return [Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])] }
func dist(_ p: [Double], _ q: [Double]) -> Double { sqrt(zip(p, q).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }) }
func med(_ v: [[Double]]) -> [Double] { (0..<3).map { c in v.map { $0[c] }.sorted()[v.count / 2] } }

    let pips = pipRects.map { (x: $0.midX * Double(w), y: $0.midY * Double(h), r: 0.5 * Double(max($0.width * Double(w), $0.height * Double(h)))) }
// 2. tile body color: the median color in the ring around the pips
var rings: [[Double]] = []
for p in pips {
    var s: [[Double]] = []
    for rr in [1.7, 2.1] { for k in 0..<12 {
        let ang = 2 * Double.pi * Double(k) / 12
        let x = Int(p.x + cos(ang) * p.r * rr), y = Int(p.y + sin(ang) * p.r * rr)
        if x >= 0, y >= 0, x < w, y < h { s.append(px(x, y)) }
    } }
    if s.count > 6 { rings.append(med(s)) }
}
let body = rings.isEmpty ? [200, 200, 200] : med(rings)
// 3. mask: body-colored pixels plus a disc over every pip
let tol = Double(ProcessInfo.processInfo.environment["TOL"] ?? "") ?? 75
var mask = [Bool](repeating: false, count: w * h)
let bodyLum = 0.3 * body[0] + 0.59 * body[1] + 0.11 * body[2]
var lum = [Double](repeating: 0, count: w * h)
for i in 0..<(w * h) { lum[i] = 0.3 * Double(rgba[4 * i]) + 0.59 * Double(rgba[4 * i + 1]) + 0.11 * Double(rgba[4 * i + 2]) }
var I1 = [Double](repeating: 0, count: (w + 1) * (h + 1)), I2 = I1
for y in 0..<h { var r1 = 0.0, r2 = 0.0; for x in 0..<w { let v = lum[y * w + x]; r1 += v; r2 += v * v; I1[(y + 1) * (w + 1) + x + 1] = I1[y * (w + 1) + x + 1] + r1; I2[(y + 1) * (w + 1) + x + 1] = I2[y * (w + 1) + x + 1] + r2 } }
// Multicolored tiles: no single tile color. A tile is anything smooth that differs from the background (the median color along the photo's border).
let multi = PipCounter.multicolor
var bgColor = [255.0, 255.0, 255.0]
do {
    var b: [[Double]] = []
    let m = max(2, w / 40)
    for x in stride(from: 0, to: w, by: 3) { for y in 0..<m { b.append(px(x, y)); b.append(px(x, h - 1 - y)) } }
    for y in stride(from: 0, to: h, by: 3) { for x in 0..<m { b.append(px(x, y)); b.append(px(w - 1 - x, y)) } }
    if !b.isEmpty { bgColor = med(b) }
}
let multiTol = Double(ProcessInfo.processInfo.environment["MULTITOL"] ?? "") ?? 80
let stdThr = Double(ProcessInfo.processInfo.environment["STD"] ?? "") ?? 8
for y in 0..<h { for x in 0..<w {
    let e = 3
    let xa = max(0, x - e), xb = min(w - 1, x + e), ya = max(0, y - e), yb = min(h - 1, y + e)
    let n = Double((xb - xa + 1) * (yb - ya + 1))
    let s1 = I1[(yb + 1) * (w + 1) + xb + 1] - I1[ya * (w + 1) + xb + 1] - I1[(yb + 1) * (w + 1) + xa] + I1[ya * (w + 1) + xa]
    let s2 = I2[(yb + 1) * (w + 1) + xb + 1] - I2[ya * (w + 1) + xb + 1] - I2[(yb + 1) * (w + 1) + xa] + I2[ya * (w + 1) + xa]
    let sd = max(0, s2 / n - (s1 / n) * (s1 / n)).squareRoot()
    if multi { mask[y * w + x] = sd < stdThr && dist(px(x, y), bgColor) > multiTol }
    else { mask[y * w + x] = sd < stdThr && dist(px(x, y), body) < tol && (bodyLum < 80 || lum[y * w + x] > 0.72 * bodyLum) }
} }
let medR = pips.isEmpty ? 6.0 : pips.map(\.r).sorted()[pips.count / 2]
for p in pips { let R = p.r * 2.2; for y in max(0, Int(p.y - R))...min(h - 1, Int(p.y + R)) { for x in max(0, Int(p.x - R))...min(w - 1, Int(p.x + R)) where hypot(Double(x) - p.x, Double(y) - p.y) <= R { mask[y * w + x] = true } } }
func morph(_ m: [Bool], _ e: Int, erode: Bool) -> [Bool] {
    var I = [Int](repeating: 0, count: (w + 1) * (h + 1))
    for y in 0..<h { var row = 0; for x in 0..<w { row += m[y * w + x] ? 1 : 0; I[(y + 1) * (w + 1) + x + 1] = I[y * (w + 1) + x + 1] + row } }
    var out = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w {
        let xa = max(0, x - e), xb = min(w - 1, x + e), ya = max(0, y - e), yb = min(h - 1, y + e)
        let cnt = I[(yb + 1) * (w + 1) + xb + 1] - I[ya * (w + 1) + xb + 1] - I[(yb + 1) * (w + 1) + xa] + I[ya * (w + 1) + xa]
        let full = (xb - xa + 1) * (yb - ya + 1)
        out[y * w + x] = erode ? cnt == full : cnt > 0
    } }
    return out
}
let maskRaw = mask
let eClose = max(1, Int(medR * 0.6)), eOpen = max(2, Int(medR * 0.9))
mask = morph(morph(mask, eClose, erode: false), eClose, erode: true)
mask = morph(morph(mask, eOpen, erode: true), eOpen, erode: false)
if !faceOnly { debugMask = (w, h, mask) }
// 4. components
var comp = [Int](repeating: -1, count: w * h)
var comps: [[Int]] = []
for i in 0..<(w * h) where mask[i] && comp[i] < 0 {
    var st = [i]; comp[i] = comps.count; var list: [Int] = []
    while let k = st.popLast() {
        list.append(k)
        let x = k % w, y = k / w
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
            let kk = ny * w + nx
            if mask[kk], comp[kk] < 0 { comp[kk] = comps.count; st.append(kk) }
        }
    }
    comps.append(list)
}
// 5. rectangle of each component (principal axes, extents)
var tiles: [FoundTile] = []
let pipTiles = comps.filter { c in c.contains { k in pips.contains { hypot(Double(k % w) - $0.x, Double(k / w) - $0.y) < 2 } } }
let refArea = pipTiles.isEmpty ? 0 : pipTiles.map(\.count).sorted()[pipTiles.count / 2]
if faceOnly {
    // quick pass: the tile color is the median color of the large smooth regions that hold pips, away from the pips
    var face: [[Double]] = []
    for c in pipTiles where c.count >= max(200, Int(0.45 * Double(refArea))) {
        for k in stride(from: 0, to: c.count, by: max(1, c.count / 600)) {
            let x = c[k] % w, y = c[k] / w
            if !maskRaw[y * w + x] || pips.contains(where: { hypot($0.x - Double(x), $0.y - Double(y)) < 2.2 * $0.r }) { continue }
            face.append(px(x, y))
        }
    }
    return Result(tiles: [], halves: [], workW: w, workH: h, faceColor: face.count >= 12 ? med(face) : nil)
}
for c in comps where c.count >= max(200, Int(0.45 * Double(refArea))) {
    let n = Double(c.count)
    let mx = c.reduce(0.0) { $0 + Double($1 % w) } / n, my = c.reduce(0.0) { $0 + Double($1 / w) } / n
    var sxx = 0.0, syy = 0.0, sxy = 0.0
    for k in c { let dx = Double(k % w) - mx, dy = Double(k / w) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
    let th = 0.5 * atan2(2 * sxy, sxx - syy)
    let ux = cos(th), uy = sin(th)
    var lo = 1e9, hi = -1e9, lo2 = 1e9, hi2 = -1e9
    for k in c { let dx = Double(k % w) - mx, dy = Double(k / w) - my; let t = dx * ux + dy * uy, s = -dx * uy + dy * ux; lo = min(lo, t); hi = max(hi, t); lo2 = min(lo2, s); hi2 = max(hi2, s) }
    var A = hi - lo, B = hi2 - lo2
    var cx = mx + ux * (hi + lo) / 2 - uy * (hi2 + lo2) / 2, cy = my + uy * (hi + lo) / 2 + ux * (hi2 + lo2) / 2
    var uxx = ux, uyy = uy
    if B > A { swap(&A, &B); let t = uxx; uxx = -uyy; uyy = t; _ = cx; _ = cy }
    tiles.append(FoundTile(cx: cx, cy: cy, ux: uxx, uy: uyy, A: A, B: B, area: c.count))
    _ = cx; _ = cy; cx = 0; cy = 0
}
// edge strength (3x3-smoothed luminance, central differences), 0...1
var edge = [Double](repeating: 0, count: w * h)
do {
    var sm = lum
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        var t = 0.0
        for dy in -1...1 { for dx in -1...1 { t += lum[(y + dy) * w + x + dx] } }
        sm[y * w + x] = t / 9
    } }
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let gx = sm[y * w + x + 1] - sm[y * w + x - 1], gy = sm[(y + 1) * w + x] - sm[(y - 1) * w + x]
        edge[y * w + x] = min(1, hypot(gx, gy) / 24)
    } }
}
// 5b. reference tile size from well-formed isolated components (aspect about 2, typical area)
var refDims: (A: Double, B: Double)? = nil
do {
    let ok = tiles.filter { $0.B > 0 && $0.A / $0.B > 1.75 && $0.A / $0.B < 2.3 }
    if !ok.isEmpty {
        let areas = ok.map { Double($0.area) }.sorted()
        let ma = areas[areas.count / 2]
        let good = ok.filter { abs(Double($0.area) - ma) < 0.25 * ma }
        if !good.isEmpty { refDims = (good.map(\.A).sorted()[good.count / 2], good.map(\.B).sorted()[good.count / 2]) }
    }
}
if refDims == nil || refDims!.A / medR < 17 || refDims!.A / medR > 30 { let A = 23.0 * medR; refDims = (A, A / 2); print("reference tile from pip size", Int(A)) }
if refDims != nil {
    let eC2 = max(1, Int(medR * (Double(ProcessInfo.processInfo.environment["EC"] ?? "") ?? 1.6)))
    mask = morph(morph(maskRaw, eC2, erode: false), eC2, erode: true)
    mask = morph(morph(mask, eOpen, erode: true), eOpen, erode: false)
}
let layoutsL: [[(Double, Double)]] = {
    func grid(_ xs: [Double], _ ys: [Double]) -> [(Double, Double)] { var p: [(Double, Double)] = []; for y in ys { for x in xs { p.append((x, y)) } }; return p }
    var L: [[(Double, Double)]] = [[]]
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
func syms(_ p: [(Double, Double)]) -> [[(Double, Double)]] {
    (0..<8).map { t in p.map { var u = $0.0, v = $0.1; if t & 1 != 0 { swap(&u, &v) }; if t & 2 != 0 { u = 1 - u }; if t & 4 != 0 { v = 1 - v }; return (u, v) } }
}
let layoutCountsAll = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 11, 12]
let symCache: [[[(Double, Double)]]] = layoutsL.map { syms($0) }
if let dims = refDims {
    print("reference tile", Int(dims.A), "x", Int(dims.B), "working px; pip radius", medR, "ratio", dims.A / medR)
    // 5c. greedy template fit: repeatedly place the 2:1 rectangle that covers the most unclaimed mask pixels
    var claimed = [Bool](repeating: false, count: w * h)
    var fitted: [FoundTile] = []
    let nA = 28, nB = 14
    func env2(_ k: String, _ d: Double) -> Double { Double(ProcessInfo.processInfo.environment[k] ?? "") ?? d }
    var tpl: [(Double, Double)] = []
    for i in 0..<nA { for j in 0..<nB { tpl.append(((Double(i) + 0.5) / Double(nA) - 0.5, (Double(j) + 0.5) / Double(nB) - 0.5)) } }
    var pipClaimed = [Bool](repeating: false, count: pips.count)
    let pipIn = Double(ProcessInfo.processInfo.environment["PIPIN"] ?? "") ?? 0.012, pipOut = Double(ProcessInfo.processInfo.environment["PIPOUT"] ?? "") ?? 0.04
    func pipTerm(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double) -> Double {
        let c = cos(th), s = sin(th)
        var t = 0.0
        for (i, p) in pips.enumerated() where !pipClaimed[i] {
            let dx = p.x - cx, dy = p.y - cy
            let u = abs(dx * c + dy * s), v = abs(-dx * s + dy * c)
            let ru = A / 2 - u, rv = B / 2 - v      // distance inside each edge
            if ru > 0.6 * p.r && rv > 0.6 * p.r { t += pipIn }
            else if ru > -1.5 * p.r && rv > -1.5 * p.r { t -= pipOut }   // a pip straddling or just outside an edge
        }
        return t
    }
    // How much of the rectangle's outline lies on an edge: a tile's border (to the mat, or the seam to a touching tile) is
    // where brightness changes, so a rectangle slid along its tile or turned a little loses this.
    func edgeTerm(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double, offs: [Double] = [-2.0, -1.0, 0.0, 1.0, 2.0]) -> Double {
        let c = cos(th), s = sin(th)
        var hit = 0.0, n = 0.0
        for side in 0..<4 {
            let count = side < 2 ? 28 : 14
            for i in 0..<count {
                let t = (Double(i) + 0.5) / Double(count) - 0.5
                var best = 0.0
                for off in offs {
                    var u = 0.0, v = 0.0
                    switch side {
                    case 0: u = t * A; v = -B / 2 + off
                    case 1: u = t * A; v = B / 2 + off
                    case 2: u = -A / 2 + off; v = t * B
                    default: u = A / 2 + off; v = t * B
                    }
                    let x = Int((cx + c * u - s * v).rounded()), y = Int((cy + s * u + c * v).rounded())
                    if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 { continue }
                    best = max(best, edge[y * w + x])
                }
                hit += best; n += 1
            }
        }
        return n > 0 ? hit / n : 0
    }
    let wEmpty = Double(ProcessInfo.processInfo.environment["WEMPTY"] ?? "") ?? 0.0
    func score(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double) -> (good: Double, claimedFrac: Double) {
        let c = cos(th), s = sin(th)
        var good = 0, cl = 0, empty = 0
        for (u, v) in tpl {
            let x = Int((cx + c * u * A - s * v * B).rounded()), y = Int((cy + s * u * A + c * v * B).rounded())
            if x < 0 || y < 0 || x >= w || y >= h { empty += 1; continue }
            let i = y * w + x
            if claimed[i] { cl += 1 } else if mask[i] { good += 1 } else { empty += 1 }
        }
        return (Double(good) / Double(tpl.count) - wEmpty * Double(empty) / Double(tpl.count), Double(cl) / Double(tpl.count))
    }
    // 5c-0. pip-driven placement: a tile is where a 2:1 rectangle holds a clean group of pips (none cut by its edges),
    // sits on the tile mask and on its own border edges. Placed first so crowded or touching tiles take their pips before
    // the mask-only fit below sees them; blank and nearly blank tiles are left to that fit.
    if env2("PIPFIT", 1) > 0 {
        let minIn = Int(env2("PIPMIN", 4)), wM = env2("PIPMASK", 5.0), wE = env2("PIPEDGE", 3.0), wS = env2("PIPSTRAD", 3.0)
        let nAng = 60
        let wL = env2("PIPLAY", 4.0)
        // how well the pips in each half of the box match a standard layout: summed distance to the best template (half-square units)
        func layoutCost(_ cx: Double, _ cy: Double, _ th: Double, _ near: [Int]) -> Double {
            let c = cos(th), s = sin(th)
            var total = 0.0
            for sg in [-1.0, 1.0] {
                var pts: [(Double, Double)] = []
                for i in near {
                    let p = pips[i]
                    let dx = p.x - cx, dy = p.y - cy
                    let a = (dx * c + dy * s) * sg, b = -dx * s + dy * c
                    if a > 0, a < dims.A / 2, abs(b) < dims.B / 2 { pts.append((a / (dims.A / 2), (b + dims.B / 2) / dims.B)) }
                }
                let n = pts.count
                if n == 0 { continue }
                if n > 12 { total += 1.5; continue }
                var best = 1e9
                for (li, cnt) in layoutCountsAll.enumerated() where cnt == n {
                    for tpl in symCache[li] {
                        var used = [Bool](repeating: false, count: n), cost = 0.0
                        for q in pts {
                            var bi = -1, bd = 1e9
                            for (k, t) in tpl.enumerated() where !used[k] { let d = hypot(q.0 - t.0, q.1 - t.1); if d < bd { bd = d; bi = k } }
                            used[bi] = true; cost += bd
                        }
                        best = min(best, cost)
                    }
                }
                total += best
            }
            return total
        }
        func pscore(_ cx: Double, _ cy: Double, _ th: Double, _ near: [Int], withEdge: Bool, layout: Bool = false) -> (Double, Int) {
            let c = cos(th), s = sin(th)
            var inN = 0, strad = 0
            for i in near {
                let p = pips[i]
                let dx = p.x - cx, dy = p.y - cy
                let ru = dims.A / 2 - abs(dx * c + dy * s), rv = dims.B / 2 - abs(-dx * s + dy * c)
                if ru > 0.6 * p.r && rv > 0.6 * p.r { inN += 1 }
                else if ru > -1.5 * p.r && rv > -1.5 * p.r { strad += 1 }
            }
            var cover = 0, tot = 0
            for (u, v) in tpl {
                let x = Int((cx + c * u * dims.A - s * v * dims.B).rounded()), y = Int((cy + s * u * dims.A + c * v * dims.B).rounded())
                tot += 1
                if x < 0 || y < 0 || x >= w || y >= h { continue }
                if claimed[y * w + x] { cover -= 2 } else if mask[y * w + x] { cover += 1 }
            }
            var sc = Double(inN) - wS * Double(strad) + wM * Double(cover) / Double(tot)
            if withEdge { sc += wE * edgeTerm(cx, cy, th, dims.A, dims.B) }
            if layout { sc -= wL * layoutCost(cx, cy, th, near) }
            return (sc, inN)
        }
        let step = max(3.0, medR * 1.5)
        for _ in 0..<30 {
            let free = pips.indices.filter { !pipClaimed[$0] }
            if free.count < minIn { break }
            var seen = Set<Int>()
            var cands: [(Double, Double, Double, Double)] = []
            for i in free {
                let p = pips[i]
                var oy = -dims.A / 2
                while oy <= dims.A / 2 {
                    var ox = -dims.A / 2
                    while ox <= dims.A / 2 {
                        let gx = Int(((p.x + ox) / step).rounded()), gy = Int(((p.y + oy) / step).rounded())
                        let key = gy * 100000 + gx
                        if !seen.contains(key) {
                            seen.insert(key)
                            let cx = Double(gx) * step, cy = Double(gy) * step
                            let near = free.filter { hypot(pips[$0].x - cx, pips[$0].y - cy) < dims.A * 0.62 }
                            if near.count >= minIn {
                                var best: (Double, Double, Double, Double)? = nil
                                for k in 0..<nAng {
                                    let th = Double(k) * Double.pi / Double(nAng)
                                    let r = pscore(cx, cy, th, near, withEdge: false)
                                    if r.1 >= minIn, best == nil || r.0 > best!.0 { best = (r.0, cx, cy, th) }
                                }
                                if let b = best { cands.append(b) }
                            }
                        }
                        ox += step
                    }
                    oy += step
                }
            }
            cands.sort { $0.0 > $1.0 }
            cands = Array(cands.prefix(120)).map { cd in
                let nr = free.filter { hypot(pips[$0].x - cd.1, pips[$0].y - cd.2) < dims.A * 0.7 }
                return (pscore(cd.1, cd.2, cd.3, nr, withEdge: true, layout: true).0, cd.1, cd.2, cd.3)
            }
            cands.sort { $0.0 > $1.0 }
            var bestFull: (Double, Double, Double, Double, Int)? = nil
            var tried: [(Double, Double, Double)] = []
            for cd in cands {
                if tried.count >= 16 { break }
                if tried.contains(where: { hypot($0.0 - cd.1, $0.1 - cd.2) < 0.4 * dims.B && abs($0.2 - cd.3) < 0.25 }) { continue }
                tried.append((cd.1, cd.2, cd.3))
                func near(_ x: Double, _ y: Double) -> [Int] { free.filter { hypot(pips[$0].x - x, pips[$0].y - y) < dims.A * 0.7 } }
                var b = (pscore(cd.1, cd.2, cd.3, near(cd.1, cd.2), withEdge: true, layout: true).0, cd.1, cd.2, cd.3)
                var st = step, ast = Double.pi / Double(nAng)
                for _ in 0..<5 {
                    var improved = b
                    for dx in [-st, 0, st] { for dy in [-st, 0, st] { for da in [-ast, 0, ast] {
                        let q = (b.1 + dx, b.2 + dy, b.3 + da)
                        let sc = pscore(q.0, q.1, q.2, near(q.0, q.1), withEdge: true, layout: true).0
                        if sc > improved.0 { improved = (sc, q.0, q.1, q.2) }
                    } } }
                    b = improved; st /= 2; ast /= 2
                }
                let n = pscore(b.1, b.2, b.3, near(b.1, b.2), withEdge: true, layout: true).1
                if n >= minIn, bestFull == nil || b.0 > bestFull!.0 { bestFull = (b.0, b.1, b.2, b.3, n) }
            }
            guard let b = bestFull, b.0 >= Double(minIn) + 1.0 else { break }
            let c = cos(b.3), sn = sin(b.3)
            let R = Int((dims.A + dims.B) * 0.6)
            for y in max(0, Int(b.2) - R)..<min(h, Int(b.2) + R) { for x in max(0, Int(b.1) - R)..<min(w, Int(b.1) + R) {
                let dx = Double(x) - b.1, dy = Double(y) - b.2
                if abs(dx * c + dy * sn) <= dims.A / 2 && abs(-dx * sn + dy * c) <= dims.B / 2 { claimed[y * w + x] = true }
            } }
            for (i, p) in pips.enumerated() where !pipClaimed[i] {
                let dx = p.x - b.1, dy = p.y - b.2
                if abs(dx * c + dy * sn) < dims.A / 2 && abs(-dx * sn + dy * c) < dims.B / 2 { pipClaimed[i] = true }
            }
            fitted.append(FoundTile(cx: b.1, cy: b.2, ux: c, uy: sn, A: dims.A, B: dims.B, area: 0))
        }
    }
    let stride0 = max(2, Int(medR * 0.5))
    let angles = 30
    for _ in 0..<40 {
        var cands: [(Double, Double, Double, Double)] = []   // score, cx, cy, th
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if mask[y * w + x] && !claimed[y * w + x] {
                    var bestHere: (Double, Double, Double, Double)? = nil
                    for k in 0..<angles {
                        let th = Double(k) * Double.pi / Double(angles)
                        let r = score(Double(x), Double(y), th, dims.A, dims.B)
                        let sc = r.good - 1.5 * r.claimedFrac + pipTerm(Double(x), Double(y), th, dims.A, dims.B)
                        if bestHere == nil || sc > bestHere!.0 { bestHere = (sc, Double(x), Double(y), th) }
                    }
                    if let b = bestHere, b.0 > 0.4 { cands.append(b) }
                }
                x += stride0
            }
            y += stride0
        }
        cands.sort { $0.0 > $1.0 }
        // refine the best few with the edge term included, keep the best result
        var bestFull: (Double, Double, Double, Double)? = nil
        var tried: [(Double, Double, Double)] = []
        func full(_ x: Double, _ y: Double, _ th: Double) -> Double {
            let r = score(x, y, th, dims.A, dims.B)
            return r.good - 1.5 * r.claimedFrac + pipTerm(x, y, th, dims.A, dims.B) + 0.7 * edgeTerm(x, y, th, dims.A, dims.B)
        }
        for cd in cands {
            if tried.count >= 10 { break }
            if tried.contains(where: { hypot($0.0 - cd.1, $0.1 - cd.2) < 0.4 * dims.B && abs($0.2 - cd.3) < 0.25 }) { continue }
            tried.append((cd.1, cd.2, cd.3))
            var b = (full(cd.1, cd.2, cd.3), cd.1, cd.2, cd.3)
            var step = Double(stride0) * 1.5, ast = Double.pi / Double(angles)
            for _ in 0..<4 {
                var improved = b
                for dx in [-step, 0, step] { for dy in [-step, 0, step] { for da in [-ast, 0, ast] {
                    let sc = full(b.1 + dx, b.2 + dy, b.3 + da)
                    if sc > improved.0 { improved = (sc, b.1 + dx, b.2 + dy, b.3 + da) }
                } } }
                b = improved; step /= 2; ast /= 2
            }
            if bestFull == nil || b.0 > bestFull!.0 { bestFull = b }
        }
        guard let b = bestFull, b.0 > 0.7 else { break }
        // claim the rectangle
        let c = cos(b.3), sn = sin(b.3)
        let R = Int((dims.A + dims.B) * 0.6)
        for y in max(0, Int(b.2) - R)..<min(h, Int(b.2) + R) { for x in max(0, Int(b.1) - R)..<min(w, Int(b.1) + R) {
            let dx = Double(x) - b.1, dy = Double(y) - b.2
            let u = dx * c + dy * sn, v = -dx * sn + dy * c
            if abs(u) <= dims.A / 2 && abs(v) <= dims.B / 2 { claimed[y * w + x] = true }
        } }
        for (i, p) in pips.enumerated() where !pipClaimed[i] {
            let dx = p.x - b.1, dy = p.y - b.2
            if abs(dx * c + dy * sn) < dims.A / 2 && abs(-dx * sn + dy * c) < dims.B / 2 { pipClaimed[i] = true }
        }
        fitted.append(FoundTile(cx: b.1, cy: b.2, ux: c, uy: sn, A: dims.A, B: dims.B, area: 0))
    }
    // fine adjustment of every fitted tile: position, angle and size are tuned so the outline sits on the tile's own edge
    // (the mask is a little larger than the tile, so the first fit is slightly oversized and a degree or two off)
    func pipsInside(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double) -> Double {
        let c = cos(th), s = sin(th)
        var t = 0.0
        for p in pips {
            let dx = p.x - cx, dy = p.y - cy
            let ru = A / 2 - abs(dx * c + dy * s), rv = B / 2 - abs(-dx * s + dy * c)
            if ru > 0.6 * p.r && rv > 0.6 * p.r { t += 0 }
            else if ru > -1.0 * p.r && rv > -1.0 * p.r { t -= 0.06 }   // a pip cut by the outline
        }
        return t
    }
    // which fitted rectangle each pixel belongs to (neighbors' pixels do not count for or against a tile)
    var ids = [Int](repeating: -1, count: w * h)
    for (k, t) in fitted.enumerated() {
        let R = Int((t.A + t.B) * 0.6)
        for y in max(0, Int(t.cy) - R)..<min(h, Int(t.cy) + R) { for x in max(0, Int(t.cx) - R)..<min(w, Int(t.cx) + R) {
            let dx = Double(x) - t.cx, dy = Double(y) - t.cy
            if abs(dx * t.ux + dy * t.uy) <= t.A / 2 && abs(-dx * t.uy + dy * t.ux) <= t.B / 2 { ids[y * w + x] = k }
        } }
    }
    // overlap of a rectangle with the tile mask: how much of it is mask, and how much mask lies just outside it
    func fit(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double, _ me: Int) -> Double {
        let c = cos(th), s = sin(th)
        var inN = 0.0, inT = 0.0
        for (u, v) in tpl {
            let x = Int((cx + c * u * A - s * v * B).rounded()), y = Int((cy + s * u * A + c * v * B).rounded())
            if x < 0 || y < 0 || x >= w || y >= h { inT += 1; continue }
            let id = ids[y * w + x]
            if id >= 0 && id != me { continue }
            inT += 1; if mask[y * w + x] { inN += 1 }
        }
        var outN = 0.0, outT = 0.0
        for side in 0..<4 {
            let count = side < 2 ? 28 : 14
            for i in 0..<count {
                let t = (Double(i) + 0.5) / Double(count) - 0.5
                for off in [2.0, 4.0] {
                    var u = 0.0, v = 0.0
                    switch side {
                    case 0: u = t * A; v = -B / 2 - off
                    case 1: u = t * A; v = B / 2 + off
                    case 2: u = -A / 2 - off; v = t * B
                    default: u = A / 2 + off; v = t * B
                    }
                    let x = Int((cx + c * u - s * v).rounded()), y = Int((cy + s * u + c * v).rounded())
                    if x < 0 || y < 0 || x >= w || y >= h { continue }
                    if ids[y * w + x] >= 0 && ids[y * w + x] != me { continue }
                    outT += 1; if mask[y * w + x] { outN += 1 }
                }
            }
        }
        return (inT > 0 ? inN / inT : 0) - 0.8 * (outT > 0 ? outN / outT : 0)
    }
    let wFit = Double(ProcessInfo.processInfo.environment["WFIT"] ?? "") ?? 1.0, wEdge = Double(ProcessInfo.processInfo.environment["WEDGE"] ?? "") ?? 0.8
    // fraction of tile i's area that lies inside any other fitted rectangle (touching is fine, overlapping is not)
    func overlapFrac(_ cx: Double, _ cy: Double, _ th: Double, _ A: Double, _ B: Double, _ me: Int) -> Double {
        let c = cos(th), s = sin(th)
        var n = 0, tot = 0
        for (u, v) in tpl {
            let x = cx + c * u * A * 0.98 - s * v * B * 0.98, y = cy + s * u * A * 0.98 + c * v * B * 0.98
            tot += 1
            for (k, o) in fitted.enumerated() where k != me {
                let dx = x - o.cx, dy = y - o.cy
                if abs(dx * o.ux + dy * o.uy) < o.A / 2 && abs(-dx * o.uy + dy * o.ux) < o.B / 2 { n += 1; break }
            }
        }
        return Double(n) / Double(max(1, tot))
    }
    var uniform: (sa: Double, sb: Double)? = nil
    for pass in 0..<Int(Double(ProcessInfo.processInfo.environment["PASSES"] ?? "") ?? 5) {
    var scales: [(Double, Double)] = []
    for i in fitted.indices {
        var t = fitted[i]
        let th0 = atan2(t.uy, t.ux)
        var cur = (cx: t.cx, cy: t.cy, th: th0, sa: uniform?.sa ?? 1.0, sb: uniform?.sb ?? 1.0)
        func obj(_ q: (cx: Double, cy: Double, th: Double, sa: Double, sb: Double)) -> Double {
            if let u = uniform, abs(q.sa - u.sa) > 1e-9 || abs(q.sb - u.sb) > 1e-9 { return -9 }
            if q.sa < 0.8 || q.sa > 1.08 || q.sb < 0.8 || q.sb > 1.08 { return -9 }
            return -6.0 * overlapFrac(q.cx, q.cy, q.th, dims.A * q.sa, dims.B * q.sb, i) + wFit * fit(q.cx, q.cy, q.th, dims.A * q.sa, dims.B * q.sb, i) + wEdge * edgeTerm(q.cx, q.cy, q.th, dims.A * q.sa, dims.B * q.sb, offs: [-1.0, 0.0, 1.0]) + pipsInside(q.cx, q.cy, q.th, dims.A * q.sa, dims.B * q.sb)
        }
        var best = obj(cur)
        var step = (p: 3.0, a: pass == 0 ? 0.04 : 0.06, s: 0.04)
        for _ in 0..<8 {
            var moved = true
            while moved {
                moved = false
                for k in 0..<7 {
                    for sgn in [-1.0, 1.0] {
                        var q = cur
                        switch k {
                        case 0: q.cx += sgn * step.p
                        case 1: q.cy += sgn * step.p
                        case 2: q.th += sgn * step.a
                        case 3: q.sa += sgn * step.s
                        case 4: q.sb += sgn * step.s
                        case 5: q.cx += sgn * step.p * cos(q.th); q.cy += sgn * step.p * sin(q.th)
                        default: q.cx -= sgn * step.p * sin(q.th); q.cy += sgn * step.p * cos(q.th)
                        }
                        let v = obj(q)
                        if v > best + 1e-6 { best = v; cur = q; moved = true }
                    }
                }
            }
            step = (step.p / 2, step.a / 2, step.s / 2)
        }
        t.cx = cur.cx; t.cy = cur.cy; t.ux = cos(cur.th); t.uy = sin(cur.th); t.A = dims.A * cur.sa; t.B = dims.B * cur.sb
        fitted[i] = t
        scales.append((cur.sa, cur.sb))
    }
    // every tile of a set is the same size: take the median size of the first pass for all, then refit position and angle
    if pass == 0, !scales.isEmpty {
        let qi = Int(Double(scales.count - 1) * (Double(ProcessInfo.processInfo.environment["SQ"] ?? "") ?? 0.25)); let sa = scales.map(\.0).sorted()[qi], sb = scales.map(\.1).sorted()[qi]
        uniform = (sa, sb)
        print("uniform tile size", Int(dims.A * sa), "x", Int(dims.B * sb))
    }
    }
    // keep fits that hold at least one pip or are well covered
    tiles = fitted.filter { t in
        let n = pips.filter { p in
            let dx = p.x - t.cx, dy = p.y - t.cy
            return abs(dx * t.ux + dy * t.uy) < t.A / 2 && abs(-dx * t.uy + dy * t.ux) < t.B / 2
        }.count
        if n > 0 { return true }
        // no pips: a blank tile is still a tile if a black divider runs across its middle: a strip that is
        // dark in itself and much darker than the tile face on both sides of it (wood grain is not).
        func meanLum(_ u0: Double, _ u1: Double) -> Double? {
            var sum = 0.0, cnt = 0
            for i in -10...10 { for j in 0...2 {
                let u = (u0 + (u1 - u0) * Double(j) / 2) * t.A, v = Double(i) / 10 * t.B * 0.4
                let x = Int((t.cx + t.ux * u - t.uy * v).rounded()), y = Int((t.cy + t.uy * u + t.ux * v).rounded())
                if x < 0 || y < 0 || x >= w || y >= h { return nil }
                sum += lum[y * w + x]; cnt += 1
            } }
            return cnt > 0 ? sum / Double(cnt) : nil
        }
        guard let c = meanLum(-0.03, 0.03), let l = meanLum(-0.2, -0.12), let r = meanLum(0.12, 0.2) else { return false }
        return c < 70 && c < 0.45 * l && c < 0.45 * r
    }
}
// 5d. divider bars: a black, neutral, elongated strip across a tile. Every tile in a photo has the same bar, which may be
// shorter than the tile is wide, so a bar gives the tile's center along its long axis and the direction of its short axis.
if (Double(ProcessInfo.processInfo.environment["BARSNAP"] ?? "") ?? 1) > 0 {
    let lightBars = bodyLum < 90
    var bm = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) {
        let r = Int(rgba[4 * i]), g = Int(rgba[4 * i + 1]), b = Int(rgba[4 * i + 2])
        let mx = max(r, g, b), mn = min(r, g, b)
        // black bars on light tiles; light bars on dark (black) tiles
        bm[i] = lightBars ? (mn > 170 && Double(mx - mn) < 0.25 * Double(mx) + 6) : (mx < 90 && Double(mx - mn) < 0.3 * Double(mx) + 6)
    }
    var seen = [Bool](repeating: false, count: w * h)
    var bars: [(cx: Double, cy: Double, dx: Double, dy: Double, len: Double, thick: Double)] = []
    for i0 in 0..<(w * h) where bm[i0] && !seen[i0] {
        var st = [i0]; seen[i0] = true; var list: [Int] = []
        while let k = st.popLast() {
            list.append(k)
            let x = k % w, y = k / w
            for (ddx, ddy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + ddx, ny = y + ddy
                if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                let kk = ny * w + nx
                if bm[kk], !seen[kk] { seen[kk] = true; st.append(kk) }
            }
        }
        if list.count < 20 || list.count > w * h / 20 { continue }
        let n = Double(list.count)
        let mx = list.reduce(0.0) { $0 + Double($1 % w) } / n, my = list.reduce(0.0) { $0 + Double($1 / w) } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for k in list { let ex = Double(k % w) - mx, ey = Double(k / w) - my; sxx += ex * ex; syy += ey * ey; sxy += ex * ey }
        let th = 0.5 * atan2(2 * sxy, sxx - syy), bx = cos(th), by = sin(th)
        var lo = 1e9, hi = -1e9, lo2 = 1e9, hi2 = -1e9
        for k in list { let ex = Double(k % w) - mx, ey = Double(k / w) - my; let a = ex * bx + ey * by, c = -ex * by + ey * bx; lo = min(lo, a); hi = max(hi, a); lo2 = min(lo2, c); hi2 = max(hi2, c) }
        let len = hi - lo, thick = hi2 - lo2
        // a bar is long and thin, and mostly solid (not a diagonal scribble of dark grain)
        guard thick >= 2, len >= 3.5 * thick, n >= 0.6 * len * thick else { continue }
        var cxb = mx + bx * (hi + lo) / 2 - by * (hi2 + lo2) / 2, cyb = my + by * (hi + lo) / 2 + bx * (hi2 + lo2) / 2
        // a glare can break a bar: grow it along its axis while the strip stays dark (or light) and neutral
        func barPix(_ x: Double, _ y: Double) -> Bool {
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            guard xi >= 0, yi >= 0, xi < w, yi < h else { return false }
            let r = Int(rgba[4 * (yi * w + xi)]), g = Int(rgba[4 * (yi * w + xi) + 1]), b = Int(rgba[4 * (yi * w + xi) + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            return lightBars ? (mn > 150 && Double(mx - mn) < 0.3 * Double(mx) + 10) : (mx < 135 && Double(mx - mn) < 0.35 * Double(mx) + 10)
        }
        var ext = [0.0, 0.0]
        for (si, sgn) in [-1.0, 1.0].enumerated() {
            var d = len / 2 + 1, miss = 0
            while d < len * 1.1 {
                let x = cxb + sgn * bx * d, y = cyb + sgn * by * d
                let hit = [-thick / 3, 0, thick / 3].filter { barPix(x - by * $0, y + bx * $0) }.count >= 2
                if hit { ext[si] = d - len / 2; miss = 0 } else { miss += 1; if miss > 3 { break } }
                d += 1
            }
        }
        let newLen = len + max(0, ext[0]) + max(0, ext[1])
        cxb += bx * (max(0, ext[1]) - max(0, ext[0])) / 2; cyb += by * (max(0, ext[1]) - max(0, ext[0])) / 2
        bars.append((cxb, cyb, bx, by, newLen, thick))
    }
    // bars are one thickness in a photo: keep those near the median thickness
    if bars.count >= 2 {
        let th = bars.map(\.thick).sorted()[bars.count / 2]
        bars = bars.filter { $0.thick >= 0.5 * th && $0.thick <= 2.0 * th }
    }
    let endBars = (Double(ProcessInfo.processInfo.environment["ENDBAR"] ?? "") ?? 1) > 0   // a bar at the end of a box centers the tile on it
    var usedBar = Set<Int>()
    var snapped = 0
    for ti in tiles.indices {
        var t = tiles[ti]
        var bi = -1, bd = 0.3 * t.B
        for (k, b) in bars.enumerated() where !usedBar.contains(k) {
            // the bar runs across the tile: its direction is perpendicular to the tile's long axis
            if abs(b.dx * t.ux + b.dy * t.uy) > 0.5 { continue }
            // it lies along the middle of the tile and is not longer than the tile is wide
            if b.len > 1.25 * t.B { continue }
            let d = hypot(b.cx - t.cx, b.cy - t.cy)
            if d < bd { bd = d; bi = k }
        }
        if bi < 0 {
            // no bar component matched (a glare or the table's shadow joined it to something): look along the tile's middle
            // for the strip across its width that is darkest and most neutral
            let thicks = bars.map(\.thick).sorted()
            let bt = thicks.isEmpty ? 4.0 : thicks[thicks.count / 2]
            var bestS = 0.0, bestF = 0.0
            var s = -0.18 * t.A
            while s <= 0.18 * t.A {
                var hit = 0, tot = 0
                for k in -8...8 {
                    let v = Double(k) / 8 * 0.4 * t.B
                    let x = t.cx + t.ux * s - t.uy * v, y = t.cy + t.uy * s + t.ux * v
                    tot += 1
                    let xi = Int(x.rounded()), yi = Int(y.rounded())
                    guard xi >= 0, yi >= 0, xi < w, yi < h else { continue }
                    let r = Int(rgba[4 * (yi * w + xi)]), g = Int(rgba[4 * (yi * w + xi) + 1]), b = Int(rgba[4 * (yi * w + xi) + 2])
                    let mx = max(r, g, b), mn = min(r, g, b)
                    if lightBars ? (mn > 150 && Double(mx - mn) < 0.3 * Double(mx) + 10) : (mx < 110 && Double(mx - mn) < 0.35 * Double(mx) + 10) { hit += 1 }
                }
                let f = Double(hit) / Double(tot)
                if f > bestF { bestF = f; bestS = s }
                s += 1
            }
            if bestF >= 0.75 {
                let bx = -t.uy, by = t.ux
                let b = (cx: t.cx + t.ux * bestS, cy: t.cy + t.uy * bestS, dx: bx, dy: by, len: 0.8 * t.B, thick: bt)
                usedBar.insert(-1 - ti)
                debugBars.append(b)
                t.cx += t.ux * bestS; t.cy += t.uy * bestS
                tiles[ti] = t
                snapped += 1
            }
            continue
        }
        usedBar.insert(bi)
        let b = bars[bi]
        if ProcessInfo.processInfo.environment["DBGN"] != nil { FileHandle.standardError.write(Data(String(format: "bar %d at (%.0f,%.0f) len %.0f thick %.0f -> tile %d at (%.0f,%.0f)\n", bi, b.cx, b.cy, b.len, b.thick, ti, t.cx, t.cy).utf8)) }
        debugBars.append(b)
        // long axis: perpendicular to the bar, same sense as before
        var ux = -b.dy, uy = b.dx
        if ux * t.ux + uy * t.uy < 0 { ux = -ux; uy = -uy }
        // slide the tile along its long axis so the bar is at its middle; its position across is kept
        let along = (b.cx - t.cx) * ux + (b.cy - t.cy) * uy
        t.cx += ux * along; t.cy += uy * along
        t.ux = ux; t.uy = uy
        tiles[ti] = t
        snapped += 1
    }
    // A bar at the end of a box (not its middle): the box holds one half of the tile (the other half is as dark as the table).
    // Slide the box along its long axis so the bar is at its middle.
    let usedLens = usedBar.filter { $0 >= 0 }.map { bars[$0].len }.sorted()
    let barLen = usedLens.isEmpty ? 0 : usedLens[usedLens.count / 2]
    // a bar fragment much shorter than the bars that matched is a glare or a scrap, not a divider
    for (k, b) in bars.enumerated() where !usedBar.contains(k) && endBars && lightBars && b.len >= 0.75 * barLen {
        var bt = -1, bd = 0.3 * (tiles.first?.B ?? 0)
        for (ti, tl) in tiles.enumerated() {
            if abs(b.dx * tl.ux + b.dy * tl.uy) > 0.5 || b.len > 1.25 * tl.B { continue }
            for s in [-1.0, 1.0] {
                let d = hypot(b.cx - (tl.cx + s * tl.ux * tl.A / 2), b.cy - (tl.cy + s * tl.uy * tl.A / 2))
                if d < bd { bd = d; bt = ti }
            }
        }
        if ProcessInfo.processInfo.environment["DBGN"] != nil { FileHandle.standardError.write(Data(String(format: "endbar %d at (%.0f,%.0f) len %.0f thick %.0f -> tile %d\n", k, b.cx, b.cy, b.len, b.thick, bt).utf8)) }
        guard bt >= 0 else { continue }
        var tl = tiles[bt]
        var nux = -b.dy, nuy = b.dx
        if nux * tl.ux + nuy * tl.uy < 0 { nux = -nux; nuy = -nuy }
        tl.ux = nux; tl.uy = nuy
        // the box held only one half, so its position across is biased too: take the bar's center (the bar is centered across the tile)
        tl.cx = b.cx; tl.cy = b.cy
        // the bar's ends are not reliable (a fragment, a glare): slide the box across the tile to the spot that holds the most pips
        func fit(_ off: Double) -> Double {
            let cx = tl.cx - tl.uy * off, cy = tl.cy + tl.ux * off
            var s = 0.0
            for p in pips {
                let dx = p.x - cx, dy = p.y - cy
                let a = abs(dx * tl.ux + dy * tl.uy), c = abs(-dx * tl.uy + dy * tl.ux)
                if a < tl.A / 2 - p.r, c < tl.B / 2 - p.r { s += 1 }
                else if a < tl.A / 2 + p.r, c < tl.B / 2 + p.r { s -= 3 }
            }
            return s
        }
        var bo = 0.0, bs = fit(0)
        // the bar lies within the tile's width, so the tile can sit off the bar's center only by the bar's slack
        let slack = max(0.0, 0.5 * (tl.B - b.len)) + 0.06 * tl.B
        var off = -slack
        while off <= slack { let v = fit(off); if v > bs + 1e-9 { bs = v; bo = off }; off += 1 }
        tl.cx -= tl.uy * bo; tl.cy += tl.ux * bo
        tiles[bt] = tl
        usedBar.insert(k); debugBars.append(b); snapped += 1
    }
    // two boxes now on one tile (each held one half): keep the one that holds more pips
    do {
        func holds(_ tl: FoundTile) -> Int { pips.filter { p in let dx = p.x - tl.cx, dy = p.y - tl.cy; return abs(dx * tl.ux + dy * tl.uy) < tl.A / 2 && abs(-dx * tl.uy + dy * tl.ux) < tl.B / 2 }.count }
        var drop = Set<Int>()
        for i in tiles.indices { for j in tiles.indices where j > i && !drop.contains(i) && !drop.contains(j) {
            let a = tiles[i], b = tiles[j]
            if hypot(a.cx - b.cx, a.cy - b.cy) < 0.4 * a.B && abs(a.ux * b.ux + a.uy * b.uy) > 0.8 { drop.insert(holds(a) >= holds(b) ? j : i) }
        } }
        if !drop.isEmpty { tiles = tiles.indices.filter { !drop.contains($0) }.map { tiles[$0] } }
    }
    if ProcessInfo.processInfo.environment["DBGN"] != nil { FileHandle.standardError.write(Data("bars=\(bars.count) snapped=\(snapped) of \(tiles.count) tiles\n".utf8)) }
}
// separate overlapping rectangles: push each pair apart along the axis of least penetration (separating axis test)
func corners(_ t: FoundTile) -> [(Double, Double)] {
    [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { (su, sv) in (t.cx + t.ux * su * t.A / 2 - t.uy * sv * t.B / 2, t.cy + t.uy * su * t.A / 2 + t.ux * sv * t.B / 2) }
}
for _ in 0..<60 {
    var moved = false
    for i in tiles.indices { for j in tiles.indices where j > i {
        let ca = corners(tiles[i]), cb = corners(tiles[j])
        var minPen = 1e9, axis = (0.0, 0.0)
        var separated = false
        for t in [tiles[i], tiles[j]] { for ax in [(t.ux, t.uy), (-t.uy, t.ux)] {
            let pa = ca.map { $0.0 * ax.0 + $0.1 * ax.1 }, pb = cb.map { $0.0 * ax.0 + $0.1 * ax.1 }
            let pen = min(pa.max()!, pb.max()!) - max(pa.min()!, pb.min()!)
            if pen <= 0.5 { separated = true }
            if pen < minPen { minPen = pen; axis = ax }
        } }
        if separated { continue }
        let dx = tiles[j].cx - tiles[i].cx, dy = tiles[j].cy - tiles[i].cy
        let sgn = (dx * axis.0 + dy * axis.1) >= 0 ? 1.0 : -1.0
        let m = (minPen / 2 + 0.3) * sgn
        tiles[i].cx -= axis.0 * m; tiles[i].cy -= axis.1 * m
        tiles[j].cx += axis.0 * m; tiles[j].cy += axis.1 * m
        moved = true
    } }
    if !moved { break }
}
// ---- layout matching per half ----
// strong: confident pips in the half's unit square; weak: extra candidates. Returns (count, cost).
let halfSizeLo = Double(ProcessInfo.processInfo.environment["HSLO"] ?? "") ?? 0.78, halfSizeHi = Double(ProcessInfo.processInfo.environment["HSHI"] ?? "") ?? 1.4
let weakFill = Double(ProcessInfo.processInfo.environment["WFILL"] ?? "") ?? 0.05, weakUnused = Double(ProcessInfo.processInfo.environment["WUNUSED"] ?? "") ?? 0.1
let weakFillMixed = Double(ProcessInfo.processInfo.environment["WMIX"] ?? "") ?? 0.45
var bestTpl: [(Double, Double)] = []
func snapHalf(_ strong: [(Double, Double)], _ weak: [(Double, Double)], tol: Double) -> (Int, Double) {
    var best = (strong.count, 99.0)
    bestTpl = []
    let shifts: [Double] = [-0.12, -0.06, 0, 0.06, 0.12]
    let scales: [Double] = [0.9, 1.0, 1.1]
    let layoutCounts = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 11, 12]
    for (li, lay) in layoutsL.enumerated() {
        let n = layoutCounts[li]
        for tpl0 in (n == 0 ? [[]] : syms(lay)) {
            for sc in scales { for dx in shifts { for dy in shifts {
                let tpl = tpl0.map { ((($0.0 - 0.5) * sc) + 0.5 + dx, (($0.1 - 0.5) * sc) + 0.5 + dy) }
                var usedS = [Bool](repeating: false, count: strong.count), usedW = [Bool](repeating: false, count: weak.count)
                var cost = 0.0
                for q in tpl {
                    if q.0 < 0.1 { cost += 1.5 }   // a pip cannot sit on the divider
                    var bi = -1, bd = tol
                    for (i, p) in strong.enumerated() where !usedS[i] { let d = hypot(p.0 - q.0, p.1 - q.1); if d < bd { bd = d; bi = i } }
                    if bi >= 0 { usedS[bi] = true; continue }
                    var wi = -1; bd = tol
                    for (i, p) in weak.enumerated() where !usedW[i] { let d = hypot(p.0 - q.0, p.1 - q.1); if d < bd { bd = d; wi = i } }
                    if wi >= 0 { usedW[wi] = true; cost += strong.isEmpty ? weakFill : weakFillMixed } else { cost += 1.0 }
                }
                cost += 1.2 * Double(usedS.filter { !$0 }.count) + weakUnused * Double(usedW.filter { !$0 }.count) + (abs(dx) + abs(dy)) * 0.4 + abs(sc - 1) * 0.4
                if cost < best.1 - 1e-9 || (abs(cost - best.1) < 1e-9 && n > best.0) { best = (n, cost); bestTpl = tpl }
            } } }
        }
    }
    return best
}
let poolPx = (poolRects + blobRects).map { (x: $0.midX * Double(w), y: $0.midY * Double(h), r: 0.5 * Double(max($0.width * Double(w), $0.height * Double(h)))) }
var halfCounts: [(tile: Int, half: Int, raw: Int, snapped: Int, cost: Double)] = []
var labelPos: [(Double, Double, Int)] = []
for (ti, t) in tiles.enumerated() {
    for (hi, sg) in [-1.0, 1.0].enumerated() {
        // half frame: u along the tile (0 at the outer end, 1 at the divider), v across (0...1)
        func toHalf(_ x: Double, _ y: Double) -> (Double, Double)? {
            let dx = x - t.cx, dy = y - t.cy
            let a = (dx * t.ux + dy * t.uy) * sg, b = -dx * t.uy + dy * t.ux
            // a runs from the divider (0) to the outer end (A/2)
            let u = a / (t.A / 2), v = b / t.B + 0.5
            if u < -0.02 || u > 1.02 || v < -0.02 || v > 1.02 { return nil }
            return (u, v)
        }
        // Pips of one half are one size: one clearly smaller or larger than the rest of its half is not a pip of it.
        var strongIdx = pips.indices.filter { toHalf(pips[$0].x, pips[$0].y) != nil }
        if strongIdx.count >= 4 {
            let rs = strongIdx.map { pips[$0].r }.sorted(), m = rs[rs.count / 2]
            let ok = strongIdx.filter { pips[$0].r >= halfSizeLo * m && pips[$0].r <= halfSizeHi * m }
            for i in strongIdx where !ok.contains(i) { droppedPips.append(CGPoint(x: pipRects[i].midX, y: pipRects[i].midY)) }
            strongIdx = ok
        }
        let strongPx = strongIdx.map { pips[$0] }
        let strong = strongPx.compactMap { toHalf($0.x, $0.y) }
        func pipColor(_ x: Double, _ y: Double, _ r: Double) -> [Double] {
            let xi = Int(x.rounded()), yi = Int(y.rounded()), e = max(1, Int(r * 0.4))
            var s = [[Double]]()
            for dy in stride(from: -e, through: e, by: max(1, e)) { for dx in stride(from: -e, through: e, by: max(1, e)) {
                let xx = xi + dx, yy = yi + dy
                if xx >= 0, yy >= 0, xx < w, yy < h { s.append(px(xx, yy)) }
            } }
            return s.isEmpty ? [0, 0, 0] : med(s)
        }
        var weakAll: [(pos: (Double, Double), color: [Double])] = []
        for q in poolPx {
            guard let p = toHalf(q.x, q.y), p.0 > 0.1, !strong.contains(where: { hypot($0.0 - p.0, $0.1 - p.1) < 0.12 }), !weakAll.contains(where: { hypot($0.pos.0 - p.0, $0.pos.1 - p.1) < 0.1 }) else { continue }
            let c = pipColor(q.x, q.y, q.r)
            if !multi, dist(c, body) < 70 { continue }       // a pip is clearly different from the tile face
            weakAll.append((p, c))
        }
        // pips of one half share a color: weak evidence must match the confident pips' color, or each other's
        let refColor: [Double]? = strongPx.isEmpty ? (weakAll.count >= 3 ? med(weakAll.map(\.color)) : nil) : med(strongPx.map { pipColor($0.x, $0.y, $0.r) })
        let weak: [(Double, Double)] = refColor.map { rc in weakAll.filter { dist($0.color, rc) < 60 }.map(\.pos) } ?? []
        let r = snapHalf(strong, weak, tol: 0.14)
        halfCounts.append((ti, hi, strong.count, r.0, r.1))
        if ProcessInfo.processInfo.environment["DBGH"] != nil { FileHandle.standardError.write(Data(String(format: "tile %d half %d at (%.0f,%.0f): strong=%d weak=%d -> %d cost %.2f\n", ti, hi, t.cx + sg * t.ux * t.A / 4, t.cy + sg * t.uy * t.A / 4, strong.count, weak.count, r.0, r.1).utf8)) }
        // pips the layout supplied where none was found: shown, so every counted pip has a dot
        if !bestTpl.isEmpty {
            let rr = strongPx.isEmpty ? medR : strongPx.map(\.r).sorted()[strongPx.count / 2]
            for q0 in bestTpl where !strong.contains(where: { hypot($0.0 - q0.0, $0.1 - q0.1) < 0.14 }) {
                // where a weaker pip was found for this spot, it is drawn where it was found
                let q = weak.min(by: { hypot($0.0 - q0.0, $0.1 - q0.1) < hypot($1.0 - q0.0, $1.1 - q0.1) }).flatMap { hypot($0.0 - q0.0, $0.1 - q0.1) < 0.14 ? $0 : nil } ?? q0
                let a = q.0 * t.A / 2, b = (q.1 - 0.5) * t.B
                let x = t.cx + sg * a * t.ux - b * t.uy, y = t.cy + sg * a * t.uy + b * t.ux
                layoutPips.append(CGRect(x: (x - rr) / Double(w), y: (y - rr) / Double(h), width: 2 * rr / Double(w), height: 2 * rr / Double(h)))
            }
        }
        let cx = t.cx + sg * t.ux * t.A / 4, cy = t.cy + sg * t.uy * t.A / 4
        labelPos.append((cx, cy, r.0))
    }
}
    var halves: [Half] = []
    for (k, hc) in halfCounts.enumerated() {
        halves.append(Half(tile: hc.tile, index: hc.half, count: hc.snapped, raw: hc.raw, center: CGPoint(x: labelPos[k].0 / Double(w), y: labelPos[k].1 / Double(h))))
    }
    // tile-face color: median color of tile-colored pixels inside the tiles, away from the pips
    var face: [[Double]] = []
    for t in tiles {
        for i in 0..<14 { for j in 0..<7 {
            let u = (Double(i) + 0.5) / 14 - 0.5, v = (Double(j) + 0.5) / 7 - 0.5
            let x = Int((t.cx + t.ux * u * t.A - t.uy * v * t.B).rounded()), y = Int((t.cy + t.uy * u * t.A + t.ux * v * t.B).rounded())
            if x < 1 || y < 1 || x >= w - 1 || y >= h - 1 || !maskRaw[y * w + x] { continue }
            if pips.contains(where: { hypot($0.x - Double(x), $0.y - Double(y)) < 2.2 * $0.r }) { continue }
            face.append(px(x, y))
        } }
    }
    return Result(tiles: tiles, halves: halves, workW: w, workH: h, faceColor: face.count >= 12 ? med(face) : nil)
    }
}
