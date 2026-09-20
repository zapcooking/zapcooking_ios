import SwiftUI

struct InterfaceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showCurrencyPicker = false
    @State private var rateUpdatedAt: Date? = nil
    #if DEBUG
    @State private var showDeveloperTools = false
    #endif

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: "Text") {
                    Toggle("Large text", isOn: $settings.largeText)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                        .padding(.vertical, 4)
                }

                section(title: "Appearance") {
                    HStack(spacing: 12) {
                        ForEach(AppSettings.ColorSchemePreference.allCases, id: \.self) { mode in
                            Button {
                                settings.colorScheme = mode
                            } label: {
                                Text(mode.rawValue.capitalized)
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(settings.colorScheme == mode ? .white : theme.palette.onSurface)
                                    .background(settings.colorScheme == mode ? theme.primary : theme.palette.surfaceVariant)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }

                section(title: "Media") {
                    Toggle("Auto-download media", isOn: $settings.autoLoadMedia)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("When off, images and link previews show a tap-to-load placeholder.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)
                    Toggle("Auto-play videos", isOn: $settings.videoAutoplay)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                        .disabled(!settings.autoLoadMedia)
                        .opacity(settings.autoLoadMedia ? 1.0 : 0.5)
                    Toggle("Loop videos", isOn: $settings.videoLoop)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Replays timeline and gallery videos from the beginning when they finish.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)
                    Toggle("Animate avatars", isOn: $settings.animateAvatars)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Plays animated GIF / WebP profile pictures inline.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)

                    HStack {
                        Text("Multi-image layout")
                            .foregroundStyle(theme.palette.onSurface)
                        Spacer()
                        Picker("", selection: $settings.mediaLayoutStyle) {
                            Text("Gallery").tag(AppSettings.MediaLayoutStyle.grid)
                            Text("Stack").tag(AppSettings.MediaLayoutStyle.stack)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.top, 4)
                    Text("Gallery: horizontal swipe through every photo and video. Stack: each item full-width below the next.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }

                section(title: "Feed") {
                    Toggle("Include replies in feeds", isOn: $settings.includeRepliesInFeed)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Shows replies from people you follow, with context about who they're replying to. When off, only top-level posts appear.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }

                section(title: "Notifications") {
                    HStack {
                        Text("List style")
                            .foregroundStyle(theme.palette.onSurface)
                        Spacer()
                        Picker("", selection: $settings.notificationFeedStyle) {
                            ForEach(AppSettings.NotificationFeedStyle.allCases, id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    Text("Expanded: every notification shows its note, zap message, or poll inline. Compact: one-line rows you tap to open.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }

                section(title: "Translation") {
                    Toggle("Auto-translate notes", isOn: $settings.autoTranslate)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Automatically translate notes that aren't in your device language.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }

                section(title: "Posting") {
                    Toggle("Zap Cooking client tag", isOn: $settings.clientTagEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Adds a [\"client\", \"Zap Cooking\"] tag so others can see you're posting from Zap Cooking.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)

                    Toggle("Undo countdown", isOn: $settings.postUndoTimerEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Holds new posts for a few seconds before publishing so you can cancel.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)

                    if settings.postUndoTimerEnabled {
                        HStack {
                            Text("Duration")
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            Picker("", selection: $settings.postUndoTimerSeconds) {
                                ForEach(AppSettings.postUndoTimerOptions, id: \.self) { secs in
                                    Text("\(secs)s").tag(secs)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                        .padding(.top, 4)

                        Toggle("Include replies", isOn: $settings.postUndoTimerForReplies)
                            .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                            .padding(.top, 4)
                        Text("Off by default — replies send immediately. Turn on to apply the same countdown to replies.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                }

                // Instant-zap configuration lives in the zap sheet's
                // "Edit Presets" now (toggle + per-preset selection), so it's
                // discoverable where it's used. There is no app-wide fiat
                // mode any more (Android has none) — zap and post surfaces
                // are always sats. The currency below is only the one the
                // wallet dashboard renders when you tap its balance into
                // fiat, so the picker stays ungated.
                section(title: "Currency") {
                    Button { showCurrencyPicker = true } label: {
                        HStack {
                            Text("Currency")
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            Text(settings.fiatCurrency)
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        }
                        .padding(.vertical, 8)
                    }
                    Text("Used by the wallet balance and transaction rows when you switch them to fiat. Zaps are always shown in sats.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                    HStack {
                        if let updated = rateUpdatedAt {
                            Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        } else {
                            Text("No exchange rate cached yet")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        }
                        Spacer()
                        Button("Refresh") {
                            Task {
                                await ExchangeRateService.shared.refresh()
                                await ExchangeRateCache.shared.updateFromService()
                                rateUpdatedAt = ExchangeRateCache.shared.updatedAt
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primary)
                    }
                }


                #if DEBUG
                // Developer playground — compiled out of release builds via
                // `#if DEBUG`. Park throwaway experiments here.
                section(title: "Developer") {
                    Button {
                        showDeveloperTools = true
                    } label: {
                        HStack {
                            Text("Developer tools")
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                #endif


                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Interface")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .sheet(isPresented: $showDeveloperTools) {
            NavigationStack { DeveloperToolsView() }
        }
        #endif
        .sheet(isPresented: $showCurrencyPicker) {
            NavigationStack {
                CurrencyPickerView()
                    .navigationTitle("Currency")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            await ExchangeRateCache.shared.updateFromService()
            rateUpdatedAt = ExchangeRateCache.shared.updatedAt
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

}

private struct CurrencyPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ExchangeRateService.supported) { currency in
            Button {
                settings.fiatCurrency = currency.code
                dismiss()
            } label: {
                HStack {
                    Text(currency.symbol)
                        .frame(width: 32, alignment: .leading)
                        .foregroundStyle(theme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currency.code)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.palette.onSurface)
                        Text(currency.name)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    Spacer()
                    if settings.fiatCurrency == currency.code {
                        Image(systemName: "checkmark")
                            .foregroundStyle(theme.primary)
                    }
                }
            }
        }
    }
}
