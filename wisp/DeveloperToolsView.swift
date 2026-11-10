#if DEBUG
import SwiftUI

/// Debug-only developer playground. Wired into `InterfaceSettingsView`
/// under a `#if DEBUG` row so it ships nowhere near a release build.
/// Pin throwaway experiments here — animation styles, prototype layouts,
/// single-shot repros — instead of building a temporary entry in
/// production code.
struct DeveloperToolsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    /// Fires an arrival's effects by hand. Notification sounds, haptics and
    /// the bottom-bar burst normally need a live relay arrival — a real
    /// reply, zap or DM landing while the app is foregrounded — which is no
    /// way to check whether the thing works. These run the same
    /// `NotificationEffectPlan` the repositories do, with the same live
    /// gates, so what you get here is what an arrival would give you.
    private var notificationEffects: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notification effects")
                .font(.headline)
                .foregroundStyle(theme.palette.onSurface)

            Text(gateSummary)
                .font(.caption)
                .foregroundStyle(theme.palette.onSurfaceVariant)

            ForEach(NotificationKind.allCases, id: \.self) { kind in
                let plan = NotificationEffectPlan.plan(
                    for: kind,
                    soundsOn: settings.notificationSoundsEnabled,
                    typeEnabled: NotificationFilterStore.loadActive()
                        .contains(NotificationFilter.bucket(for: kind))
                )
                Button {
                    plan.fire()
                } label: {
                    HStack {
                        Text(kind.rawValue)
                            .foregroundStyle(theme.palette.onSurface)
                        Spacer()
                        Text(describe(plan))
                            .font(.caption.monospaced())
                            .foregroundStyle(plan == .none
                                             ? theme.palette.onSurfaceVariant.opacity(0.6)
                                             : theme.primary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3)
            }

            // The burst draws on the Notifications tab, behind this sheet,
            // and lasts under a second — so it needs a head start to be
            // watchable.
            Button {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    NotificationBurstStore.shared.fireZap()
                }
                dismiss()
            } label: {
                Text("Zap burst in 3s (closes this, watch the bell)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(theme.primary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    /// Why a row might be silent: the global toggle, or a muted type.
    private var gateSummary: String {
        let enabled = NotificationFilterStore.loadActive()
        let muted = NotificationFilter.allCases.filter { !enabled.contains($0) }
        let sound = settings.notificationSoundsEnabled ? "sounds on" : "sounds OFF (toggle in Notifications)"
        let types = muted.isEmpty
            ? "all types enabled"
            : "muted: \(muted.map(\.rawValue).sorted().joined(separator: ", "))"
        return "\(sound) · \(types)"
    }

    private func describe(_ plan: NotificationEffectPlan) -> String {
        var parts: [String] = []
        // Show the tone that will actually play, not the effect's category —
        // replies and activity follow the Interface settings pickers.
        if let sound = plan.sound {
            parts.append("♪ \(NotificationSounds.resourceName(for: sound))")
        }
        if let haptic = plan.haptic { parts.append("~ \(haptic)") }
        if let burst = plan.burst { parts.append("✦ \(burst)") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "  ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                notificationEffects
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: dismiss.callAsFunction)
            }
        }
    }
}

#Preview {
    NavigationStack { DeveloperToolsView() }
        .environment(AppSettings.shared)
}
#endif
