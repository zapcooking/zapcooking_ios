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
                // Android's spacing is not uniform — 16 under the bell, 8
                // under DONE!, 20 above the dismiss hint — so the stack
                // spaces nothing and each element carries its own.
                VStack(spacing: 0) {
                    // Android's outlined `ic_bell_done`, not a filled bell:
                    // the solid SF Symbol read as a much heavier mark at the
                    // same point size.
                    Image("ZapBellDone")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .foregroundStyle(Color.wispPrimary)
                    Text("DONE!")
                        .font(AppFont.timerDisplay(size: 42))
                        // Android's 0.06em at 42 pt.
                        .tracking(42 * 0.06)
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.top, 16)
                    if !timer.label.isEmpty {
                        Text(timer.label)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                    Text("Tap anywhere to dismiss")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.5))
                        .padding(.top, 20)
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
