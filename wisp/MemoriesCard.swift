import SwiftUI

/// Dismissible "Memories" teaser (port of Android `MemoriesCard`). Shows
/// only when the signed-in user has memories for today and hasn't dismissed
/// it. Tapping opens the full Memories screen (`onOpen`); the X dismisses for
/// the day with a 5s Undo. Self-contained and read-only — loads through
/// `MemoriesRepository`'s per-day cache, so it doesn't re-query on every feed
/// open, and the repository coalesces a load the full screen may be running.
///
/// Rendered from the top slot of BOTH feed bodies (see
/// `FeedTabRouting.showsMemoriesTeaser`); the card renders nothing at all on a
/// day with no memories, so it costs no layout on empty days.
struct MemoriesCard: View {
    let pubkey: String
    let onOpen: () -> Void
    var repo: MemoriesRepository = .shared

    @State private var dismissed = false
    @State private var undoVisible = false
    @State private var groups: [MemoryGroup]?
    @State private var undoTask: Task<Void, Never>?

    private var nonEmpty: [MemoryGroup] {
        (groups ?? []).filter { !$0.events.isEmpty }.sorted { $0.yearsAgo < $1.yearsAgo }
    }

    var body: some View {
        Group {
            if !dismissed, !nonEmpty.isEmpty {
                teaser
            } else if dismissed, undoVisible {
                undoRow
            }
        }
        .task(id: pubkey) {
            dismissed = repo.isCardDismissed(pubkey: pubkey)
            undoVisible = false
            groups = nil
            if dismissed { return }
            let loaded = await repo.getMemoriesCached(pubkey: pubkey)
            if !Task.isCancelled { groups = loaded }
        }
    }

    static func summary(for groups: [MemoryGroup], calendar: Calendar = .current) -> String {
        let total = groups.reduce(0) { $0 + $1.events.count }
        let years = groups.map { String(calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0.dateSec)))) }
        return "\(total) \(total == 1 ? "note" : "notes") · \(years.joined(separator: ", "))"
    }

    private var teaser: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.wispPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memories")
                            .font(AppFont.bodyMedium.weight(.semibold))
                            .foregroundStyle(Color.wispOnSurface)
                        Text("A look back at notes from this day")
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                        Text(Self.summary(for: nonEmpty))
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Memories. \(Self.summary(for: nonEmpty)). Opens a look back at notes from this day.")

            Button {
                repo.dismissCard(pubkey: pubkey)
                dismissed = true
                undoVisible = true
                undoTask?.cancel()
                undoTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { undoVisible = false }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide memories for today")
        }
        .background(Color.wispSurfaceVariant.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("memories-teaser")
    }

    private var undoRow: some View {
        HStack {
            Text("Memories hidden")
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Spacer()
            Button("Undo") {
                undoTask?.cancel()
                repo.undismissCard(pubkey: pubkey)
                undoVisible = false
                dismissed = false
            }
            .font(AppFont.bodySmall.weight(.semibold))
            .foregroundStyle(Color.wispPrimary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .background(Color.wispSurfaceVariant.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("memories-undo")
    }
}
