import SwiftUI

/// Sheet for picking a future date+time for a scheduled post. Returns the
/// chosen `Date` to the caller via `onConfirm`, or nil via `onCancel`.
///
/// The scheduler takes a time from 5 minutes to 90 days out
/// (`docs/schedule-contract.md` in zapcooking/frontend), so the picker offers
/// exactly that, measured on `NostrClock` rather than the device clock: the
/// server judges the time by its own clock, and a phone that is a few minutes
/// off should not offer times the server will refuse.
struct ScheduleSheet: View {
    let initialDate: Date?
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    /// When the limits were last measured. Moved forward when a stale pick
    /// is refused, so the picker's range catches up with the clock.
    @State private var now: Int
    /// Opens tall: at the medium height the graphical picker's time row, and
    /// the line that states the limits, sit below the fold.
    @State private var detent: PresentationDetent = .large

    init(initialDate: Date? = nil,
         onConfirm: @escaping (Date) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialDate = initialDate
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let now = NostrClock.now()
        _now = State(initialValue: now)
        _selectedDate = State(initialValue: Self.initialSelection(initialDate, now: now))
    }

    /// The times the picker offers, as whole minutes: the first minute at
    /// least 5 minutes off, to the last minute under 90 days off.
    static func allowedRange(now: Int) -> ClosedRange<Date> {
        let earliest = now + ScheduleApi.pickerMinLeadSeconds
        let latest = now + ScheduleApi.maxLeadSeconds - 1
        let lower = ((earliest + 59) / 60) * 60
        let upper = (latest / 60) * 60
        return Date(timeIntervalSince1970: TimeInterval(lower))...Date(timeIntervalSince1970: TimeInterval(upper))
    }

    /// Where the picker opens: the time already set if it is still on offer,
    /// otherwise 15 minutes from now.
    static func initialSelection(_ initialDate: Date?, now: Int) -> Date {
        let range = allowedRange(now: now)
        if let initialDate, range.contains(initialDate) { return initialDate }
        let fallback = ((now + 15 * 60 + 59) / 60) * 60
        return Date(timeIntervalSince1970: TimeInterval(fallback))
    }

    /// The pick as it is handed back: on the minute, so a post goes out at
    /// 9:00 and not at 9:00:37.
    static func onTheMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((Int(date.timeIntervalSince1970) / 60) * 60))
    }

    private var range: ClosedRange<Date> { Self.allowedRange(now: now) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    in: range,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal, 12)

                Text("Pick a time from 5 minutes to 90 days from now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("schedule-limits")

                Spacer()
            }
            .navigationTitle("Schedule Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") {
                        // The sheet may have sat open while the clock moved:
                        // measure again, and keep a pick that has slipped
                        // under 5 minutes on screen at the new earliest time.
                        let fresh = NostrClock.now()
                        let picked = Self.onTheMinute(selectedDate)
                        let allowed = Self.allowedRange(now: fresh)
                        guard allowed.contains(picked) else {
                            now = fresh
                            selectedDate = min(max(picked, allowed.lowerBound), allowed.upperBound)
                            return
                        }
                        onConfirm(picked)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }
}
