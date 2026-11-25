#if DEBUG
import SwiftUI
import UIKit

/// Debug-only host for a two-column grid of real `RecipeCardView`s, reached
/// with the `-RecipeGridHarness` launch argument — the same pattern as
/// `-NotificationRowHarness`. Every card carries a wide landscape photo (3:1),
/// the shape that overflows the 2:3 poster sideways when scaled to fill, so a
/// UI test can tap each poster and check which recipe opens. No login and no
/// network: the photos are drawn here and seeded into `DecodedImageCache`, and
/// the destination is a label naming the route rather than the detail screen.
struct RecipeGridHarness: View {
    static let dTags = ["left-one", "right-one", "left-two", "right-two"]

    private let events: [NostrEvent]

    init() {
        let colors: [UIColor] = [.systemOrange, .systemTeal, .systemPink, .systemIndigo]
        events = zip(Self.dTags, colors).enumerated().map { index, pair in
            let (dTag, color) = pair
            let url = "https://harness.invalid/\(dTag).jpg"
            if let parsed = URL(string: url) {
                DecodedImageCache.storeStatic(
                    Self.landscapePhoto(color),
                    for: InlineMediaLoader.staticKey(url: parsed, maxPixelSize: nil)
                )
            }
            return NostrEvent(
                id: String(repeating: String(index + 1), count: 64),
                pubkey: String(repeating: "a", count: 64),
                kind: 30023,
                createdAt: 1_700_000_000 + index,
                tags: [
                    ["d", dTag],
                    ["title", dTag.replacingOccurrences(of: "-", with: " ").capitalized],
                    ["image", url],
                ],
                content: "",
                sig: ""
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                    spacing: 12
                ) {
                    ForEach(events, id: \.id) { event in
                        RecipeCardView(event: event)
                    }
                }
                .padding(.horizontal, 12)
            }
            .background(Color.wispBackground)
            .navigationTitle("Recipe grid")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RecipeRoute.self) { route in
                Text("Opened \(route.dTag)")
                    .accessibilityIdentifier("opened-recipe")
            }
        }
    }

    /// A 3:1 photo stand-in: a flat colour with a diagonal, so a screenshot
    /// shows it was cropped rather than squeezed.
    private static func landscapePhoto(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 900, height: 300)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.5).setStroke()
            let line = UIBezierPath()
            line.move(to: .zero)
            line.addLine(to: CGPoint(x: size.width, y: size.height))
            line.lineWidth = 12
            line.stroke()
        }
    }
}
#endif
