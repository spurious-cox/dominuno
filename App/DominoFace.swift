import SwiftUI

/// One end of a domino (0 to 12 pips), drawn on an ivory tile.
struct DominoFace: View {
    let pips: Int

    var body: some View {
        Canvas { ctx, size in
            let pts = DominoFace.layout(pips)
            let rows: CGFloat = pips >= 10 ? 4 : 3
            let r = min(size.width / 3, size.height / rows) * 0.16
            let inset = size.width * 0.2
            let w = size.width - 2 * inset, h = size.height - 2 * inset
            for p in pts {
                let x = inset + w * p.x / 2
                let y = inset + h * p.y / (rows - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.black))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.95, blue: 0.86),
                                              Color(red: 0.90, green: 0.84, blue: 0.70)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.45), lineWidth: 0.75))
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(pips == 0 ? "Double blank" : "\(pips)")
    }

    /// Pip positions on a 3-column grid: x in 0...2, y in 0...(rows-1); 3 rows up to 9, 4 rows for 10–12.
    static func layout(_ n: Int) -> [CGPoint] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let corners = [p(0, 0), p(2, 0), p(0, 2), p(2, 2)]
        let sides3 = [p(0, 0), p(0, 1), p(0, 2), p(2, 0), p(2, 1), p(2, 2)]
        let sides4 = (0..<4).flatMap { y in [p(0, CGFloat(y)), p(2, CGFloat(y))] }
        switch n {
        case 1: return [p(1, 1)]
        case 2: return [p(2, 0), p(0, 2)]
        case 3: return [p(2, 0), p(1, 1), p(0, 2)]
        case 4: return corners
        case 5: return corners + [p(1, 1)]
        case 6: return sides3
        case 7: return sides3 + [p(1, 1)]
        case 8: return sides3 + [p(1, 0), p(1, 2)]
        case 9: return sides3 + [p(1, 0), p(1, 1), p(1, 2)]
        case 10: return sides4 + [p(1, 1), p(1, 2)]
        case 11: return sides4 + [p(1, 0.5), p(1, 1.5), p(1, 2.5)]
        case 12: return sides4 + (0..<4).map { p(1, CGFloat($0)) }
        default: return []
        }
    }
}
