import SwiftUI

/// My Kitchen › Nourish — Android `NourishEntrySection` copy verbatim.
/// CTA pushes `NourishExploreRoute` when `NourishGate.entryVisible`.
struct NourishPlaceholderView: View {
    @Binding var path: NavigationPath

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🥦")
                .font(.system(size: 40))
            Text("Nourish")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            Text("See how recipes nourish you — explore the catalog by gut health, protein, heart health, and more.")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                path.append(NourishExploreRoute())
            } label: {
                Text("Explore Nourish")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.wispPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!NourishGate.entryVisible())
            .opacity(NourishGate.entryVisible() ? 1 : 0.5)
            .accessibilityIdentifier("explore-nourish")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
