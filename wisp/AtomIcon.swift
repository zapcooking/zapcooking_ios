import SwiftUI

/// The Intelligence (AI tools) glyph: a nucleus orbited by three elliptical
/// electron paths at 0°/60°/120°.
///
/// Ported from Zap Cooking Android's `AtomIcon` in `IntelligenceMenu.kt`,
/// which in turn mirrors the web client's `IntelligenceIcon` — same
/// proportions expressed as fractions of the glyph box, so it stays crisp
/// at any size: orbits are 46% × 18% of the box, stroked at 6%, around a
/// nucleus of 9%.
///
/// Replaces the `sparkles` SF Symbol the Recipes bar used to carry.
struct AtomIcon: View {
    var size: CGFloat = 24
    var tint: Color

    /// Orbit tilts, in degrees.
    private let orbits: [Double] = [0, 60, 120]

    var body: some View {
        Canvas { ctx, canvas in
            let w = canvas.width, h = canvas.height
            let center = CGPoint(x: w / 2, y: h / 2)
            let rx = w * 0.46, ry = h * 0.18
            let oval = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)

            for angle in orbits {
                var ctx = ctx
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: .degrees(angle))
                ctx.translateBy(x: -center.x, y: -center.y)
                ctx.stroke(Path(ellipseIn: oval), with: .color(tint), lineWidth: w * 0.06)
            }

            let r = w * 0.09
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(tint)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        AtomIcon(size: 20, tint: .primary)
        AtomIcon(size: 24, tint: .orange)
        AtomIcon(size: 44, tint: .secondary)
    }
    .padding()
}
