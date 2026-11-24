import SwiftUI

/// One end of a domino (0 to 12 pips), drawn on an ivory tile.
struct DominoFace: View {
    let pips: Int

    var body: some View {
        Canvas { ctx, size in
            let pts = DominoFace.layout(pips)
            let rows: CGFloat = pips >= 10 ? 4 : 3
            // As large as the pattern allows without pips touching.
            let side = min(size.width, size.height)
            let r = side * (rows == 4 ? 0.075 : 0.1)
            let inset = side * 0.18
            let w = size.width - 2 * inset, h = size.height - 2 * inset
            let color = DominoFace.color(pips)
            for p in pts {
                let x = inset + w * p.x / 2
                let y = inset + h * p.y / (rows - 1)
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(color))
                // A thin rim keeps light colors (yellow) readable on the ivory tile.
                ctx.stroke(dot, with: .color(.black.opacity(0.35)), lineWidth: max(0.5, r * 0.15))
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

    /// The usual color-dot double-12 set: each number of pips has its own color.
    static func color(_ n: Int) -> Color {
        switch n {
        case 1: return Color(red: 0.20, green: 0.62, blue: 0.90)   // light blue
        case 2: return Color(red: 0.12, green: 0.60, blue: 0.24)   // green
        case 3: return Color(red: 0.86, green: 0.14, blue: 0.14)   // red
        case 4: return Color(red: 0.52, green: 0.30, blue: 0.13)   // brown
        case 5: return Color(red: 0.10, green: 0.20, blue: 0.70)   // dark blue
        case 6: return Color(red: 0.96, green: 0.76, blue: 0.05)   // yellow
        case 7: return Color(red: 0.58, green: 0.30, blue: 0.75)   // purple
        case 8: return Color(red: 0.05, green: 0.42, blue: 0.40)   // dark green
        case 9: return Color(red: 0.06, green: 0.12, blue: 0.40)   // navy
        case 10: return Color(red: 0.96, green: 0.45, blue: 0.08)  // orange
        case 11: return Color(red: 0.10, green: 0.10, blue: 0.10)  // black
        case 12: return Color(red: 0.50, green: 0.50, blue: 0.52)  // gray
        default: return .black
        }
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
