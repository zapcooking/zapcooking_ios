import SwiftUI

/// The thread's "No replies yet" dead end.
///
/// The mark is the brand pan-and-zap — the `ZcLogo` artwork — painted in
/// **one quiet grey**. Full circle back to C-J's sweep: `ZcLogo` originally
/// lost this spot because its light/dark variants' structural whites could
/// vanish on a same-coloured ground. A fixed half-grey has no variant to
/// lose: it sits 44–55 max-channel points off either shipped theme ground
/// (`0xD8D8D8`, `0x111827`) and is structurally capped at 64 on any ground
/// — visible, never loud.
///
/// The two SVG paths are drawn directly (even-odd fills, via `SvgPath`)
/// rather than templating the asset: flattening the multi-path asset into
/// a template image drops the bolt that lives inside the lens hole. Filled
/// explicitly, the bolt cannot fall out. `EmptyStateGroundTests` measures
/// ring, bolt and handle from rendered pixels on both grounds.
struct NoRepliesEmptyState: View {
    static let iconSize: CGFloat = 64

    /// The one quiet grey: neutral half-grey at half opacity.
    static let tint = Color(.sRGB, white: 0.5, opacity: 0.5)

    var body: some View {
        VStack(spacing: 8) {
            NoRepliesMark(size: Self.iconSize, tint: Self.tint)
            Text("No replies yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread-no-replies")
    }
}

/// The Zc mark: pan ring + handle (with its hang-hole and lens cut out by
/// the even-odd rule) and the Zap bolt sitting in the lens. Path data is
/// the logo SVG verbatim (viewBox 0 0 456 456), scaled to the proposed
/// frame.
private struct NoRepliesMark: View {
    var size: CGFloat
    var tint: Color

    static let ring = SvgPath.parse(
        "M190.68 381.35C227.22 381.35 261.36 371.07 290.36 353.25C315.02 338.1 329.21 350.55 339.92 362.99L412.89 447.74C421.03 457.19 435.48 457.73 444.3 448.91L448.93 444.28C457.75 435.46 457.21 421.01 447.76 412.87L363.01 339.9C350.57 329.19 338.11 315 353.27 290.34C371.09 261.34 381.37 227.2 381.37 190.66C381.37 154.12 371.11 120.05 353.32 91.06C350.3 86.15 349.35 80.28 349.14 74.52C348.77 64.18 344.36 53.59 336.06 45.28C327.76 36.98 317.16 32.57 306.83 32.2C301.07 31.99 295.21 31.04 290.29 28.02C261.28 10.26 227.18 0 190.68 0C138.03 0 90.36 21.34 55.85 55.85C21.34 90.35 0 138.02 0 190.68C0 227.18 10.26 261.29 28.05 290.27C31.07 295.19 32.02 301.05 32.23 306.81C32.6 317.15 37.01 327.74 45.31 336.05C53.61 344.35 64.21 348.76 74.55 349.13C80.31 349.34 86.17 350.29 91.09 353.31C120.08 371.1 154.18 381.36 190.68 381.36V381.35ZM398.99 398.98C397.13 400.84 396.96 403.81 398.61 405.86L419.91 432.46C423.24 436.62 429.44 436.96 433.21 433.19C436.98 429.42 436.63 423.22 432.48 419.89L405.88 398.59C403.82 396.94 400.86 397.11 399 398.97L398.99 398.98ZM302.32 302.31C240.67 363.96 140.71 363.96 79.05 302.31C17.4 240.66 17.4 140.7 79.05 79.04C140.7 17.39 240.66 17.39 302.32 79.04C363.97 140.69 363.97 240.65 302.32 302.31Z"
    )
    static let bolt = SvgPath.parse(
        "M256.47 167.22C255.44 165.04 253.31 163.69 250.9 163.69H208.99L208.79 163.43L225.04 100.91C225.78 98.04 224.51 95.21 221.87 93.87C219.23 92.53 216.2 93.16 214.32 95.45L125.94 203.16C124.41 205.02 124.1 207.53 125.13 209.7C126.16 211.88 128.29 213.23 130.7 213.23H172.61L172.81 213.49L156.56 276.01C155.82 278.88 157.09 281.71 159.73 283.05C160.65 283.52 161.62 283.75 162.57 283.75C164.34 283.75 166.06 282.96 167.28 281.47L255.66 173.76C257.19 171.9 257.5 169.39 256.47 167.22Z"
    )

    var body: some View {
        ZStack {
            ScaledPath(path: Self.ring).fill(tint, style: FillStyle(eoFill: true))
            ScaledPath(path: Self.bolt).fill(tint, style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Draws a pre-parsed path (authored in a 456-unit space) scaled to fit
/// whatever rect the layout proposes.
private struct ScaledPath: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 456
        return path.applying(CGAffineTransform(scaleX: s, y: s))
    }
}
