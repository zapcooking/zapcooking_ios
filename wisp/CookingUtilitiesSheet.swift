import SwiftUI

/// The Gadgets sheet — timers and the unit converter, ported from Zap
/// Cooking Android's `CookingUtilitiesSheet`. Concern 1.8a for the timer;
/// the converter followed once the timers were settled.
///
/// Android's own header rather than a navigation bar: two tab pills on the
/// left, minimise and close on the right. The timer half is the same manual
/// / preset UI cook mode opens from a step — no regex over step text lives
/// here.
struct CookingUtilitiesSheet: View {
    @Bindable var store: CookingTimerStore
    var onDismiss: () -> Void

    enum Tab: String, CaseIterable { case timer, converter }

    @State private var tab: Tab = .timer
    @State private var label = ""
    @State private var minutesText = "5"
    @FocusState private var minutesFocused: Bool

    // Converter state. Persisted so a calculation survives closing and
    // reopening the sheet, which is torn down on dismiss — Android backs the
    // same three values with its prefs for the same reason.
    @AppStorage("converter_amount") private var amountText = ""
    @AppStorage("converter_from") private var fromAbbrev = CookingConverter.defaultFrom
    @AppStorage("converter_to") private var toAbbrev = CookingConverter.defaultTo

    private var minutes: Int { Int(minutesText) ?? 0 }
    private var canAdd: Bool { minutes > 0 && minutes <= CookingTimerStore.maxMinutes }

    private var fromUnit: CookingConverter.Unit {
        CookingConverter.unit(stored: fromAbbrev, fallback: CookingConverter.defaultFrom)
    }
    private var toUnit: CookingConverter.Unit {
        CookingConverter.unit(stored: toAbbrev, fallback: CookingConverter.defaultTo)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                switch tab {
                case .timer: timerTab
                case .converter: converterTab
                }
            }
        }
        .background(Color.wispBackground)
        // Not `.large`: Android's bottom sheet stops short of the top so the
        // feed stays visible behind it. Opens at the shorter detent and can
        // still be dragged up.
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.hidden)
        .task { await store.prepareNotifications() }
    }

    // MARK: - Header

    /// Android's `SheetHeader`: tab pills leading, minimise + close trailing.
    private var header: some View {
        HStack(spacing: 8) {
            tabPill(.timer, label: "Timer", systemImage: "timer")
            tabPill(.converter, label: "Converter", systemImage: "plus.forwardslash.minus")
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabPill(_ value: Tab, label text: String, systemImage: String) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : Color.wispOnSurfaceVariant)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(selected ? Color.wispPrimary : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("gadgets-tab-\(value.rawValue)")
    }

    // MARK: - Timer tab

    private var timerTab: some View {
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
                .outlinedField()
            TextField("", text: $minutesText)
                .outlinedField()
                .keyboardType(.numberPad)
                .focused($minutesFocused)
                .frame(width: 72)
                .accessibilityLabel("Minutes")
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

    /// Android's row of six equal-width outlined buttons — not filled
    /// chips. Content is the primary colour, which is what an
    /// `OutlinedButton` gives you there.
    private var quickChips: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4).padding(.vertical, 14)
            HStack(spacing: 6) {
                ForEach(CookingTimerPresets.quickMinutes, id: \.self) { minutes in
                    Button {
                        _ = store.addTimer(label: "", minutes: minutes)
                    } label: {
                        Text("\(minutes)m")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.wispPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 9)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.wispOutline.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(minutes) minute timer")
                }
            }
            .padding(.bottom, 18)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4)
            Text("COOKING PRESETS")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .padding(.top, 14)
                .padding(.bottom, 12)

            // Fixed rows of four rather than an adaptive grid: Android lays
            // them out in chunks of four and the names are written to fit
            // that width.
            let rows = stride(from: 0, to: CookingTimerPresets.cooking.count, by: 4).map {
                Array(CookingTimerPresets.cooking[$0..<min($0 + 4, CookingTimerPresets.cooking.count)])
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.name) { preset in
                        Button {
                            _ = store.addTimer(label: preset.name, minutes: preset.minutes)
                        } label: {
                            VStack(spacing: 0) {
                                Text(preset.emoji).font(.system(size: 26))
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.wispOnSurface)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.top, 6)
                                Text("\(preset.minutes) min")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.wispOnSurfaceVariant)
                                    .padding(.top, 2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.wispOutline.opacity(0.6), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.name), \(preset.minutes) minutes")
                    }
                    // Keep a short last row aligned with the one above it.
                    ForEach(0..<(4 - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Converter tab

    /// Android's converter tab: amount, From picker, a swap button, To
    /// picker, the result slab, then the quick presets.
    private var converterTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("Amount")
                Spacer()
                Button("Clear") {
                    amountText = ""
                    fromAbbrev = CookingConverter.defaultFrom
                    toAbbrev = CookingConverter.defaultTo
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isConverterDefault ? Color.wispOnSurfaceVariant.opacity(0.4) : Color.wispPrimary)
                .disabled(isConverterDefault)
            }
            .padding(.top, 20)

            TextField("0", text: Binding(
                get: { amountText },
                set: { amountText = CookingConverter.sanitizeAmount($0) }
            ))
            .keyboardType(.decimalPad)
            .outlinedField()
            .padding(.top, 8)
            .accessibilityIdentifier("converter-amount")

            sectionLabel("From").padding(.top, 16)
            unitPicker(
                selection: $fromAbbrev,
                fallback: CookingConverter.defaultFrom,
                partnerOf: $toAbbrev,
                partnerFallback: CookingConverter.defaultTo,
                id: "converter-from"
            )
                .padding(.top, 8)

            HStack {
                Spacer()
                Button {
                    let old = fromAbbrev
                    fromAbbrev = toAbbrev
                    toAbbrev = old
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .frame(width: 48, height: 48)
                        .background(Color.wispSurfaceVariant.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swap units")
                .accessibilityIdentifier("converter-swap")
                Spacer()
            }
            .padding(.top, 12)

            sectionLabel("To").padding(.top, 12)
            unitPicker(
                selection: $toAbbrev,
                fallback: CookingConverter.defaultTo,
                partnerOf: $fromAbbrev,
                partnerFallback: CookingConverter.defaultFrom,
                id: "converter-to"
            )
                .padding(.top, 8)

            resultSlab.padding(.top, 16)

            Divider().opacity(0.4).padding(.top, 18)

            Text("QUICK PRESETS")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .padding(.top, 14)

            FlowLayout(spacing: 8) {
                ForEach(CookingConverter.quickPresets) { preset in
                    Button {
                        amountText = CookingConverter.formatResult(preset.amount)
                        fromAbbrev = preset.unit.abbrev
                        if toUnit.category != preset.unit.category {
                            toAbbrev = CookingConverter.partner(for: preset.unit).abbrev
                        }
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.wispPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.wispOutline.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 36)
        }
        .padding(.horizontal, 16)
    }

    private var isConverterDefault: Bool {
        amountText.isEmpty
            && fromAbbrev == CookingConverter.defaultFrom
            && toAbbrev == CookingConverter.defaultTo
    }

    /// Nil until the amount parses — an empty or half-typed field shows the
    /// em dash rather than a stale number.
    private var converterResult: Double? {
        guard let amount = Double(amountText) else { return nil }
        return CookingConverter.convert(amount, from: fromUnit, to: toUnit)
    }

    private var resultSlab: some View {
        let result = converterResult
        return Text(result.map { "\(CookingConverter.formatResult($0)) \(toUnit.abbrev)" } ?? "—")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(result == nil ? Color.wispOnSurfaceVariant.opacity(0.4) : Color.wispOnSurface)
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("converter-result")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.wispOnSurfaceVariant)
    }

    /// Picking a unit from another category drags its partner along, so the
    /// pair is never left describing an impossible conversion.
    private func unitPicker(
        selection: Binding<String>,
        fallback: String,
        partnerOf partner: Binding<String>,
        partnerFallback: String,
        id: String
    ) -> some View {
        let selected = CookingConverter.unit(stored: selection.wrappedValue, fallback: fallback)
        return Menu {
            ForEach(CookingConverter.Category.allCases, id: \.self) { category in
                Section(category.rawValue.capitalized) {
                    ForEach(CookingConverter.allUnits.filter { $0.category == category }) { unit in
                        Button(unit.abbrev) {
                            let other = CookingConverter.unit(stored: partner.wrappedValue,
                                                              fallback: partnerFallback)
                            if other.category != unit.category {
                                partner.wrappedValue = CookingConverter.partner(for: unit).abbrev
                            }
                            selection.wrappedValue = unit.abbrev
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(selected.abbrev)
                    .foregroundStyle(Color.wispOnSurface)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier(id)
    }
}

/// Android's 3 pt timer bar: a 25%-opacity outline track with a primary
/// fill, rather than a stock `ProgressView` whose height and inset are
/// platform-decided and read thicker than Android's.
private struct TimerProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.wispOutline.opacity(0.25))
                Capsule()
                    .fill(Color.wispPrimary)
                    .frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 3)
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
            // Android's metrics: 2 pt under the label, 6 pt either side of a
            // 3 pt progress bar. The default VStack spacing and a stock
            // ProgressView left the card noticeably looser than Android's.
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.label)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .lineLimit(1)
                Text(timer.status == .done ? "Done!" : CookingTimer.formatRemaining(remaining))
                    .font(AppFont.timerDisplay(size: 28))
                    .monospacedDigit()
                    .tracking(-0.28)
                    .foregroundStyle(timer.status == .done ? Color.wispPrimary : Color.wispOnSurface)
                    .padding(.top, 2)
                if timer.status == .running, timer.duration > 0 {
                    TimerProgressBar(value: remaining / timer.duration)
                        .padding(.top, 6)
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
                .padding(.top, 6)
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

private extension View {
    /// Android's `OutlinedTextField`: a 56 pt box with a 12 pt rounded
    /// outline, sitting on the sheet's own ground.
    ///
    /// iOS's `.roundedBorder` style was doing none of that — it paints an
    /// opaque near-black fill with its own inset shape, so on a dark sheet
    /// the fields read as holes punched in the card rather than as inputs,
    /// and they came out shorter than everything beside them. A fixed
    /// height rather than padding keeps them level with the 48 pt add
    /// button regardless of the text's own line height.
    func outlinedField() -> some View {
        self
            .font(.system(size: 16))
            .foregroundStyle(Color.wispOnSurface)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(Color.wispSurfaceVariant.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispOutline.opacity(0.6), lineWidth: 1)
            )
    }
}
