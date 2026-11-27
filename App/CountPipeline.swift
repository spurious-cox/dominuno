import CoreGraphics
import Foundation

/// The whole count: pips, then tiles and halves, then (when no tile color was given) a second pip pass that uses the tile
/// color measured from the tiles found in the first pass.
enum CountPipeline {
    struct Output {
        var pips: [CGRect]
        var halves: [TileHalves.Half]
        var tiles: [FoundTile]
        var workW: Int, workH: Int
        /// Divider bars found (working-image pixels), drawn under a tint.
        var bars: [(cx: Double, cy: Double, dx: Double, dy: Double, len: Double, thick: Double)] = []
        /// Pips counted by layout matching, summed over the halves.
        var total: Int { halves.reduce(0) { $0 + $1.count } }
    }

    static func run(_ image: CGImage, tileAt: CGPoint? = nil) -> Output {
        var r = PipCounter.count(image, tileAt: tileAt)
        if tileAt == nil, !PipCounter.multicolor, let face = TileHalves.analyze(image, pips: r.pips, pool: [], faceOnly: true).faceColor {
            r = PipCounter.count(image, tileColor: face)
        }
        let th = TileHalves.analyze(image, pips: r.pips, pool: PipCounter.poolRects, blobs: PipCounter.blobRects)
        let dropped = TileHalves.droppedPips
        let shown = r.pips.filter { p in !dropped.contains { abs($0.x - p.midX) < 1e-6 && abs($0.y - p.midY) < 1e-6 } }
        return Output(pips: shown + TileHalves.layoutPips, halves: th.halves, tiles: th.tiles, workW: th.workW, workH: th.workH, bars: TileHalves.debugBars)
    }
}
