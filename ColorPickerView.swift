import SwiftUI

struct AccentColorPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1

    var body: some View {
        VStack(spacing: 24) {
            preview
            sbSquare
            hueBar
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(theme.palette.onSurface)
                    .background(theme.palette.surfaceVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("Use color") {
                    settings.accentColorARGB = Int(currentARGB())
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(currentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .background(theme.palette.background.ignoresSafeArea())
        .onAppear {
            let (h, s, b) = Self.hsv(from: settings.accentColorARGB)
            hue = h; saturation = s; brightness = b
        }
    }

    private var currentColor: Color {
        Color(hue: hue / 360.0, saturation: saturation, brightness: brightness)
    }

    private func currentARGB() -> UInt32 {
        let (r, g, b) = Self.hsvToRgb(h: hue, s: saturation, v: brightness)
        let a: UInt32 = 0xFF
        return (a << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    // MARK: - Preview swatch

    private var preview: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(currentColor)
            .frame(height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.palette.outline, lineWidth: 1)
            )
    }

    // MARK: - Saturation × Brightness square

    private var sbSquare: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let baseHueColor = Color(hue: hue / 360.0, saturation: 1, brightness: 1)
            ZStack {
                Rectangle().fill(baseHueColor)
                Rectangle().fill(LinearGradient(
                    colors: [.white, .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                ))
                Rectangle().fill(LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top, endPoint: .bottom
                ))
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().stroke(.black, lineWidth: 1))
                    .frame(width: 18, height: 18)
                    .position(x: saturation * size, y: (1 - brightness) * size)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = max(0, min(1, value.location.x / size))
                    brightness = max(0, min(1, 1 - Double(value.location.y / size)))
                }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Hue bar

    private var hueBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0/6.0).map {
                        Color(hue: $0, saturation: 1, brightness: 1)
                    },
                    startPoint: .leading, endPoint: .trailing
                )
                Capsule()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Capsule().stroke(.black, lineWidth: 1))
                    .frame(width: 8, height: 36)
                    .offset(x: max(0, min(width - 8, hue / 360.0 * width)))
            }
            .frame(height: 36)
            .clipShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let x = max(0, min(width, value.location.x))
                    hue = x / width * 360.0
                }
            )
        }
        .frame(height: 36)
    }

    // MARK: - HSV / ARGB conversion

    private static func hsv(from argb: Int) -> (Double, Double, Double) {
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        let maxC = max(r, g, b), minC = min(r, g, b)
        let d = maxC - minC
        var h: Double = 0
        if d > 0 {
            if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        let s = maxC == 0 ? 0 : d / maxC
        return (h, s, maxC)
    }

    private static func hsvToRgb(h: Double, s: Double, v: Double) -> (Int, Int, Int) {
        let c = v * s
        let hh = h / 60.0
        let x = c * (1 - Swift.abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        var r1: Double = 0, g1: Double = 0, b1: Double = 0
        switch Int(hh.rounded(.down)) {
        case 0: r1 = c; g1 = x; b1 = 0
        case 1: r1 = x; g1 = c; b1 = 0
        case 2: r1 = 0; g1 = c; b1 = x
        case 3: r1 = 0; g1 = x; b1 = c
        case 4: r1 = x; g1 = 0; b1 = c
        default: r1 = c; g1 = 0; b1 = x
        }
        let m = v - c
        return (
            Int(((r1 + m) * 255).rounded()),
            Int(((g1 + m) * 255).rounded()),
            Int(((b1 + m) * 255).rounded())
        )
    }
}
