import SwiftUI

/// My Kitchen › Nourish — placeholder slot only (Concern 3.2). Android's
/// `NourishEntrySection` copy verbatim (`strings.xml:947–949`); the button
/// is inert here. Concern C-F (Phase 3.5) wires the Nourish explore route
/// and enables it — no logic lands in 3.2.
struct NourishPlaceholderView: View {
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
                // Concern C-F wires the Nourish explore route.
            } label: {
                Text("Explore Nourish")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.wispPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.5)
            .accessibilityIdentifier("explore-nourish")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
