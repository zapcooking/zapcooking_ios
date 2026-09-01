import SwiftUI

/// Cheffy — Zap Cooking's kitchen-companion mascot (Concern C-E). A
/// **compact** port of the web `CheffyIcon.svelte` color variant: a rounded
/// face under an oversized, slightly tilted chef toque whose right fold is
/// a **Zap lightning accent** (the signature). The toque uses the app
/// theme's primary so it tints with the palette; face/ink/bolt are the
/// web's fixed brand colors. The `character` (torso + arms) variant is not
/// ported — nothing on iOS renders it above 88 pt.
///
/// Built from the web's exact SVG path data (viewBox 0 0 64 64) through
/// `SvgPath` so the silhouette matches the web and Android at any size.
struct CheffyIcon: View {
    var size: CGFloat = 24
    var expression: Cheffy.Expression = .neutral

    private static let face = Color(red: 0xF6 / 255, green: 0xDC / 255, blue: 0xA6 / 255)
    private static let ink = Color(red: 0x3A / 255, green: 0x24 / 255, blue: 0x15 / 255)
    private static let bolt = Color(red: 0xFF / 255, green: 0xC8 / 255, blue: 0x3A / 255)
    private static let boltEdge = Color(red: 0xC2 / 255, green: 0x3A / 255, blue: 0x00 / 255)

    var body: some View {
        let hat = Color.wispPrimary
        let g = CheffyIconGeometry.geometry(for: expression)
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 64
            context.scaleBy(x: s, y: s)

            // Face.
            context.fill(CheffyIconGeometry.face, with: .color(Self.face))

            // Toque (band + 3 puffs + Zap), tilted -4° about (32,18) like the web.
            context.drawLayer { hatCtx in
                hatCtx.translateBy(x: 32, y: 18)
                hatCtx.rotate(by: .degrees(-4))
                hatCtx.translateBy(x: -32, y: -18)
                hatCtx.fill(Path(ellipseIn: CGRect(x: 20.5 - 9, y: 12.5 - 9, width: 18, height: 18)), with: .color(hat))
                hatCtx.fill(Path(ellipseIn: CGRect(x: 32 - 10, y: 8.5 - 10, width: 20, height: 20)), with: .color(hat))
                hatCtx.fill(Path(ellipseIn: CGRect(x: 43.5 - 8, y: 13 - 8, width: 16, height: 16)), with: .color(hat))
                hatCtx.fill(CheffyIconGeometry.band, with: .color(hat))
                // Zap fold accent — the signature feature.
                hatCtx.fill(CheffyIconGeometry.zap, with: .color(Self.bolt))
                hatCtx.stroke(CheffyIconGeometry.zap, with: .color(Self.boltEdge), lineWidth: 0.8)
            }

            // Eyes.
            if g.eyeStyle == .happy {
                let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round)
                context.stroke(CheffyIconGeometry.happyLeftEye, with: .color(Self.ink), style: stroke)
                context.stroke(CheffyIconGeometry.happyRightEye, with: .color(Self.ink), style: stroke)
            } else {
                let r: CGFloat
                switch g.eyeStyle {
                case .wide: r = 3.9
                case .small: r = 2.8
                default: r = 3.3 // round, up
                }
                let dy: CGFloat = g.eyeStyle == .up ? -0.8 : 0
                for cx in [CheffyIconGeometry.leftEye, CheffyIconGeometry.rightEye] {
                    let cy = CheffyIconGeometry.eyeY + dy
                    context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), with: .color(Self.ink))
                    let hr = r * 0.32
                    context.fill(
                        Path(ellipseIn: CGRect(x: cx + 1.1 - hr, y: cy - 1.1 - hr, width: 2 * hr, height: 2 * hr)),
                        with: .color(.white)
                    )
                }
            }

            // Brow + mouth.
            context.stroke(g.brow, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
            if g.mouthFilled {
                context.fill(g.mouth, with: .color(Self.ink))
            } else {
                context.stroke(g.mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The web SVG geometry, parsed once. Mirrors the web `CheffyIcon`
/// expression switch (eyes/brow/mouth per mood) and Android `CheffyIcon.kt`.
nonisolated enum CheffyIconGeometry {
    enum EyeStyle { case round, wide, small, happy, up }

    struct Geometry {
        let eyeStyle: EyeStyle
        let mouth: Path
        let mouthFilled: Bool
        let brow: Path
    }

    static let leftEye: CGFloat = 25.6
    static let rightEye: CGFloat = 38.6
    static let eyeY: CGFloat = 39

    static let face = SvgPath.parse(
        "M32 22.5 C19.8 22.5 13 30.5 13 39.5 C13 50.2 21.2 56.5 32 56.5 C42.8 56.5 51 50.2 51 39.5 C51 30.5 44.2 22.5 32 22.5 Z"
    )
    static let band = SvgPath.parse(
        "M16.5 18 L47.5 18 Q49 18 49 20.5 L49 23.5 Q49 25.5 47 25.5 L17 25.5 Q15 25.5 15 23.5 L15 20.5 Q15 18 16.5 18 Z"
    )
    static let zap = SvgPath.parse("M46 6 L40.4 14.5 L45 14.5 L39.4 23.5 L52 11.5 L46.4 11.5 L50.4 6 Z")
    static let happyLeftEye = SvgPath.parse("M22.6 40 Q25.6 36.4 28.6 40")
    static let happyRightEye = SvgPath.parse("M35.6 40 Q38.6 36.4 41.6 40")

    static func geometry(for expression: Cheffy.Expression) -> Geometry {
        switch expression {
        case .happy:
            return Geometry(
                eyeStyle: .happy, mouth: SvgPath.parse("M26.8 45.6 Q32.7 51.8 38.4 45.8"),
                mouthFilled: false, brow: SvgPath.parse("M35.4 32.6 Q38.6 30.8 41.8 32.2")
            )
        case .thinking:
            return Geometry(
                eyeStyle: .up, mouth: SvgPath.parse("M30.4 48.4 Q33.2 47.2 35.8 48.8"),
                mouthFilled: false, brow: SvgPath.parse("M35.2 31.2 Q38.8 29.5 42.2 31.0")
            )
        case .excited:
            return Geometry(
                eyeStyle: .wide, mouth: SvgPath.parse("M27.4 45.2 Q32.5 53.0 37.6 45.2 Z"),
                mouthFilled: true, brow: SvgPath.parse("M35.2 31.4 Q38.6 29.6 42.0 31.2")
            )
        case .concerned:
            return Geometry(
                eyeStyle: .small, mouth: SvgPath.parse("M28.8 49.0 Q32.5 46.4 36.2 49.0"),
                mouthFilled: false, brow: SvgPath.parse("M35.4 31.0 Q38.4 32.2 41.8 30.6")
            )
        case .cooking:
            return Geometry(
                eyeStyle: .small, mouth: SvgPath.parse("M28.0 46.0 Q32.6 51.2 37.0 46.0"),
                mouthFilled: false, brow: SvgPath.parse("M35.4 32.2 Q38.6 30.5 41.8 31.8")
            )
        case .neutral:
            return Geometry(
                eyeStyle: .round, mouth: SvgPath.parse("M28.6 46.4 Q33.0 49.8 36.8 46.4"),
                mouthFilled: false, brow: SvgPath.parse("M35.6 33.0 Q38.6 31.3 41.6 32.6")
            )
        }
    }
}

/// Minimal SVG path-data parser — the absolute `M L C Q Z` subset the
/// Cheffy artwork uses (Android gets this from Compose's `PathParser`;
/// SwiftUI has no equivalent). Anything outside that subset is a
/// programmer error in the constant above, so it is skipped rather than
/// thrown. Unit-tested in `CheffyTests`.
nonisolated enum SvgPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        var index = d.startIndex

        func flush() {
            switch command {
            case "M":
                if numbers.count >= 2 { path.move(to: CGPoint(x: numbers[0], y: numbers[1])) }
                // Subsequent coordinate pairs after M are implicit L.
                var i = 2
                while i + 1 < numbers.count {
                    path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1]))
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < numbers.count {
                    path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1]))
                    i += 2
                }
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    path.addCurve(
                        to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                        control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                        control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    )
                    i += 6
                }
            case "Q":
                var i = 0
                while i + 3 < numbers.count {
                    path.addQuadCurve(
                        to: CGPoint(x: numbers[i + 2], y: numbers[i + 3]),
                        control: CGPoint(x: numbers[i], y: numbers[i + 1])
                    )
                    i += 4
                }
            case "Z", "z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll(keepingCapacity: true)
        }

        while index < d.endIndex {
            let ch = d[index]
            if ch.isLetter {
                flush()
                command = ch
                index = d.index(after: index)
            } else if ch == "-" || ch == "." || ch.isNumber {
                var end = d.index(after: index)
                while end < d.endIndex, d[end] == "." || d[end].isNumber {
                    end = d.index(after: end)
                }
                if let value = Double(d[index..<end]) { numbers.append(CGFloat(value)) }
                index = end
            } else {
                index = d.index(after: index)
            }
        }
        flush()
        return path
    }
}
