import SwiftUI

/// Android `TimerCompletionOverlay`: full-screen "DONE!" + label, tap anywhere
/// to dismiss. Concern 1.8a.
struct TimerCompletionOverlay: View {
    let timer: CookingTimer?
    var onDismiss: () -> Void

    var body: some View {
        if let timer {
            ZStack {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                VStack(spacing: 16) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.wispPrimary)
                    Text("DONE!")
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.wispPrimary)
                    if !timer.label.isEmpty {
                        Text(timer.label)
                            .font(AppFont.titleMedium)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    Text("Tap anywhere to dismiss")
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.5))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 28))
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("cooking-timer-done")
        }
    }
}
