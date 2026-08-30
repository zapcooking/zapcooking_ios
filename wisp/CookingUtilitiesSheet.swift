import SwiftUI

/// Android `CookingUtilitiesSheet` timer tab only. Converter is a follow-up
/// (Gadgets parity, but it proves nothing about timers). Concern 1.8a.
///
/// This is the same manual / preset UI 1.8b will open from a cook-mode step.
/// No regex over step text lives here.
struct CookingUtilitiesSheet: View {
    @Bindable var store: CookingTimerStore
    var onDismiss: () -> Void

    @State private var label = ""
    @State private var minutesText = "5"
    @FocusState private var minutesFocused: Bool

    private var minutes: Int { Int(minutesText) ?? 0 }
    private var canAdd: Bool { minutes > 0 && minutes <= CookingTimerStore.maxMinutes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.showsDeniedPauseCopy {
                        deniedBanner
                    }
                    addRow
                    if store.timers.isEmpty {
                        emptyState
                    } else {
                        timerList
                    }
                    quickChips
                    presets
                }
                .padding(16)
            }
            .background(Color.wispBackground)
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
        .presentationDetents([.large])
        .task { await store.prepareNotifications() }
    }

    private var deniedBanner: some View {
        Text(CookingTimerCopy.pausedWithoutNotifications)
            .font(AppFont.bodySmall)
            .foregroundStyle(Color.wispOnSurface)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("cooking-timer-denied-copy")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("min", text: $minutesText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .focused($minutesFocused)
                .frame(width: 64)
                .onChange(of: minutesText) { _, value in
                    let digits = value.filter(\.isNumber)
                    minutesText = String(digits.prefix(3))
                }
            Text("min")
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Button {
                if store.addTimer(label: label, minutes: minutes) != nil {
                    label = ""
                    minutesText = "5"
                    minutesFocused = false
                }
            } label: {
                Text("+")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(canAdd ? Color.wispBackground : Color.wispOnSurfaceVariant)
                    .frame(width: 48, height: 48)
                    .background(
                        canAdd ? Color.wispPrimary : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add timer")
        }
    }

    private var emptyState: some View {
        Text("No active timers")
            .font(AppFont.bodyMedium)
            .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private var timerList: some View {
        VStack(spacing: 8) {
            ForEach(store.timers) { timer in
                ActiveTimerCard(
                    timer: timer,
                    onPause: { store.pause(id: timer.id) },
                    onResume: { store.resume(id: timer.id) },
                    onReset: { store.reset(id: timer.id) },
                    onRemove: { store.cancel(id: timer.id) }
                )
            }
            if store.timers.contains(where: { $0.status == .done }) {
                Button("Clear finished") { store.clearFinished() }
                    .font(AppFont.bodyMedium)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var quickChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 6) {
                ForEach(CookingTimerPresets.quickMinutes, id: \.self) { minutes in
                    Button {
                        _ = store.addTimer(label: "", minutes: minutes)
                    } label: {
                        Text("\(minutes)m")
                            .font(AppFont.bodyMedium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                Color.wispSurfaceVariant.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(minutes) minute timer")
                }
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("COOKING PRESETS")
                .font(AppFont.bodySmall)
                .fontWeight(.bold)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .tracking(1)
            let rows = stride(from: 0, to: CookingTimerPresets.cooking.count, by: 4).map {
                Array(CookingTimerPresets.cooking[$0..<min($0 + 4, CookingTimerPresets.cooking.count)])
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.name) { preset in
                        Button {
                            _ = store.addTimer(label: preset.name, minutes: preset.minutes)
                        } label: {
                            VStack(spacing: 6) {
                                Text(preset.emoji).font(.title2)
                                Text(preset.name)
                                    .font(AppFont.bodySmall)
                                    .fontWeight(.medium)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .foregroundStyle(Color.wispOnSurface)
                                Text("\(preset.minutes) min")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.wispOnSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.wispOutline.opacity(0.6), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.name), \(preset.minutes) minutes")
                    }
                    if row.count < 4 {
                        ForEach(0..<(4 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

private struct ActiveTimerCard: View {
    let timer: CookingTimer
    var onPause: () -> Void
    var onResume: () -> Void
    var onReset: () -> Void
    var onRemove: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                Text(timer.label)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .lineLimit(1)
                Text(timer.status == .done ? "Done!" : CookingTimer.formatRemaining(remaining))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(timer.status == .done ? Color.wispPrimary : Color.wispOnSurface)
                if timer.status == .running, timer.duration > 0 {
                    ProgressView(value: remaining / timer.duration)
                        .tint(Color.wispPrimary)
                }
                HStack {
                    Spacer()
                    if timer.status == .paused {
                        Button("Resume", action: onResume)
                    } else if timer.status == .running {
                        Button("Pause", action: onPause)
                    } else {
                        Button(action: onReset) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Restart")
                    }
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove timer")
                }
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                timer.status == .done
                    ? Color.wispPrimary.opacity(0.18)
                    : Color.wispSurfaceVariant.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
    }
}
