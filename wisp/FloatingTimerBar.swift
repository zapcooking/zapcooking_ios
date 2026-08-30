import SwiftUI

/// Android `FloatingTimerBar`: soonest timer + `+$n` extras. Hidden while
/// the Gadgets sheet is up. Concern 1.8a.
struct FloatingTimerBar: View {
    @Bindable var store: CookingTimerStore
    var isSheetVisible: Bool
    var onExpand: () -> Void

    var body: some View {
        if !isSheetVisible, let featured = store.nextFinishing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                FloatingTimerBarContent(
                    timer: featured,
                    extraCount: store.extraActiveCount,
                    remaining: featured.remaining(at: context.date),
                    showsDeniedCopy: store.showsDeniedPauseCopy,
                    onExpand: onExpand,
                    onDismiss: { store.cancel(id: featured.id) }
                )
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct FloatingTimerBarContent: View {
    let timer: CookingTimer
    let extraCount: Int
    let remaining: TimeInterval
    let showsDeniedCopy: Bool
    var onExpand: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDeniedCopy {
                Text(CookingTimerCopy.pausedWithoutNotifications)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityIdentifier("cooking-timer-denied-copy")
            }
            HStack(spacing: 8) {
                Text(timer.status == .done ? "Done!" : CookingTimer.formatRemaining(remaining))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(timer.status == .done ? Color.wispPrimary : Color.wispOnSurface)
                    .opacity(timer.status == .running ? 1 : 0.75)
                Spacer(minLength: 0)
                Image(systemName: "timer")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
                Text(extraCount > 0 ? "\(timer.label)  +\(extraCount)" : timer.label)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .lineLimit(1)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss timer")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.wispSurfaceVariant)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens cooking timers")
    }
}
