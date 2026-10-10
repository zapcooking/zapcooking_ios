import SwiftUI

/// State + logic for the composer's GIF picker on gifs.nostr.build.
///
/// Ported from the web composer (Sidecar behavior): nothing loads until a
/// topic chip is tapped or text is entered — there is no trending list —
/// typing searches once it pauses (350 ms), suggestions replace the chips
/// while typing, pages of 24 append into a shortest-column-first masonry
/// grid deduplicated by URL, and paging stops at the query's `count` or the
/// API's offset-199 ceiling. Picking attaches the GIF's already-hosted URL;
/// nothing is uploaded.
@Observable @MainActor
final class GifPickerModel {
    var query = ""

    private(set) var columns: [[Gif]] = []
    private(set) var chips: [String] = GifSearch.topicsFor()
    private(set) var statusText = ""
    private(set) var statusIsError = false
    private(set) var loading = false

    /// How many GIFs have been laid out (columns flattened back into order).
    private(set) var placedCount = 0

    private var placed: [Gif] = []
    private var seen: Set<String> = []
    private var colHeights: [Double] = []
    private var columnCount = 0
    private var nextOffset: Int?

    /// The query behind whatever the grid is showing (nil = nothing
    /// searched). A paused-debounce run whose trimmed query matches it is
    /// skipped, so the follow-up task after a chip tap or submit doesn't
    /// re-ask for the page that search just fetched.
    private var searchedQuery: String?

    /// Whether the visible tail of the grid is close enough to the bottom
    /// that a new page should load. Maintained by cell `onAppear` — the
    /// SwiftUI equivalent of the web picker's scroll-position check.
    private var tailVisible = false

    private var pageTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    private let client: GifSearchClient

    init(client: GifSearchClient = GifSearchClient()) {
        self.client = client
    }

    // MARK: - Driving the model

    /// Called by the view's `.task(id: query)` — restarts on every keystroke,
    /// so the sleep doubles as the 350 ms debounce. Searched once typing
    /// pauses, not per keystroke: each search is a request and each one
    /// replaces the grid.
    func typingPaused() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        if q.isEmpty {
            chips = GifSearch.topicsFor()
            clearGrid()
            setStatus("Search or pick a topic.")
            return
        }
        guard q != searchedQuery else { return }
        runSearch(q)
        runSuggest(q)
    }

    /// Chip tap and keyboard submit: search this term now, no debounce.
    /// (Web parity: neither taps the suggest endpoint.)
    func searchNow(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        query = term
        chips = GifSearch.topicsFor()
        guard !term.isEmpty else {
            clearGrid()
            setStatus("Search or pick a topic.")
            return
        }
        runSearch(term)
    }

    /// A grid cell came on screen. Near the tail it both records that the
    /// bottom is visible and asks for the next page. (The web picker reads
    /// scroll offsets for this; per-cell appearance within the last few
    /// placed GIFs is the SwiftUI equivalent.)
    func cellAppeared(at index: Int) {
        tailVisible = index >= placedCount - 8
        guard tailVisible, let next = nextOffset, !loading else { return }
        load(next)
    }

    /// Lay the grid out for a new width (device rotation, sheet resize):
    /// rebuild the columns and re-place what is already showing, in order.
    func ensureColumnCount(forWidth width: CGFloat) {
        // As many columns as the width takes, about `columnWidth` each, two
        // to five. Two in the narrowest case; more where two would stretch
        // every GIF awkwardly wide.
        let count = Int(min(5, max(2, (width / GifSearch.columnWidth).rounded())))
        guard count != columnCount else { return }
        let items = placed
        columnCount = count
        columns = Array(repeating: [], count: count)
        colHeights = Array(repeating: 0, count: count)
        placed = []
        seen = []
        place(items)
    }

    /// The cell's index in placement order — near the tail it pages.
    func indexInPlaced(of gif: Gif) -> Int? {
        placed.firstIndex { $0.url == gif.url }
    }

    /// Cancel in-flight work when the sheet goes away.
    func close() {
        pageTask?.cancel()
        suggestTask?.cancel()
    }

    // MARK: - Requests

    private func runSearch(_ q: String) {
        clearGrid()
        setStatus("")
        searchedQuery = q
        load(0)
    }

    private func clearGrid() {
        pageTask?.cancel()
        nextOffset = nil
        searchedQuery = nil
        placed = []
        seen = []
        placedCount = 0
        if columnCount > 0 {
            columns = Array(repeating: [], count: columnCount)
            colHeights = Array(repeating: 0, count: columnCount)
        }
    }

    private func load(_ offset: Int) {
        pageTask?.cancel()
        loading = true
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.client.search(query: q, offset: offset)
                // A superseded page (new search, sheet closed) applies nothing
                // and must not clear the newer request's loading state.
                guard !Task.isCancelled else { return }
                self.apply(page: page, offset: offset, query: q)
                self.loading = false
            } catch is CancellationError {
                return
            } catch let error as GifSearchError {
                guard !Task.isCancelled else { return }
                self.setStatus(error.message, isError: true)
                self.loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.setStatus(GifSearch.errorMessage(forStatus: 0), isError: true)
                self.loading = false
            }
        }
    }

    private func apply(page: GifPage, offset: Int, query q: String) {
        place(page.gifs)
        nextOffset = page.next
        if offset == 0 && page.gifs.isEmpty && !q.isEmpty {
            setStatus("No GIFs found for “\(q)”.")
        } else {
            setStatus("")
        }
        // A page of duplicates or rejected items doesn't grow the grid, so no
        // cell onAppear follows: if the bottom is what's showing, ask for the
        // next page directly — only when the cursor actually moved, so a
        // cursor that doesn't move can't loop.
        if GifSearch.pageAdvanced(offset, page.next), tailVisible, let next = page.next {
            load(next)
        }
    }

    private func runSuggest(_ q: String) {
        suggestTask?.cancel()
        suggestTask = Task { [weak self] in
            guard let self else { return }
            // Suggestions are a nicety: a failure leaves the chips as they
            // were. Only the query they were asked for may show them.
            guard let terms = try? await self.client.suggest(query: q),
                  !Task.isCancelled,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            self.chips = terms
        }
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusText = text
        statusIsError = isError
    }

    // MARK: - Masonry

    /// Columns packed shortest-first, so GIFs of every shape fit without
    /// cropping. Lazy container layouts would do the packing but reflow every
    /// earlier GIF on each new page.
    private func place(_ gifs: [Gif]) {
        guard columnCount > 0 else { return }
        var nextColumns = columns
        var nextHeights = colHeights
        for gif in gifs {
            guard !seen.contains(gif.url) else { continue }
            seen.insert(gif.url)
            placed.append(gif)
            guard let col = nextHeights.indices.min(by: { nextHeights[$0] < nextHeights[$1] }) else { continue }
            nextHeights[col] += gif.height / gif.width
            nextColumns[col].append(gif)
        }
        columns = nextColumns
        colHeights = nextHeights
        placedCount = placed.count
    }
}

/// The composer's GIF picker sheet: search gifs.nostr.build, tap a GIF, and
/// its URL (already hosted on a Nostr media host) is attached to the note —
/// nothing is re-uploaded. The GIF's title seeds the attachment's alt text.
struct GifPickerView: View {
    @State private var model = GifPickerModel()
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var onSelect: (Gif) -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let gridWidth = proxy.size.width - 32
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        credit
                        searchField
                        if !model.chips.isEmpty {
                            chipsRow
                        }
                        grid
                        if !model.statusText.isEmpty {
                            Text(model.statusText)
                                .font(.caption)
                                .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("gif-picker-status")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                // Measured once the sheet is showing (a hidden picker has no
                // width to divide) and again on rotation/resize. State must
                // not change during body evaluation, so this hops onChange.
                .onAppear { model.ensureColumnCount(forWidth: gridWidth) }
                .onChange(of: gridWidth) { _, new in
                    model.ensureColumnCount(forWidth: new)
                }
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // No auto-focus: raising the keyboard on open would squeeze the
        // sheet and leave the grid no room (the complaint this fixes). The
        // field takes focus when tapped; scrolling the grid drops the
        // keyboard again via scrollDismissesKeyboard.
        .onDisappear { model.close() }
        .task(id: model.query) { await model.typingPaused() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gif-picker")
    }

    /// Attribution the gifs.nostr.build registration asks for.
    private var credit: some View {
        HStack(spacing: 3) {
            Text("GIFs from")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("nostr.build", destination: URL(string: "https://nostr.build")!)
                .font(.caption)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search GIFs", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { model.searchNow(model.query) }
                .accessibilityIdentifier("gif-picker-search")
            if !model.query.isEmpty {
                Button {
                    model.searchNow("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Topic chips while the field is empty, search suggestions while typing.
    private var chipsRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.chips, id: \.self) { term in
                Button {
                    searchFocused = false
                    model.searchNow(term)
                } label: {
                    Text(term)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("gif-chip-\(term)")
            }
        }
    }

    private var grid: some View {
        Group {
            if model.loading && model.placedCount == 0 {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else if model.placedCount == 0 {
                Color.clear.frame(minHeight: 96)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { _, column in
                        // Lazy, so cells materialize as they scroll into view —
                        // an `onAppear` near the tail means the bottom really
                        // is showing (a plain stack would fire every cell at
                        // once and page the whole list in immediately).
                        LazyVStack(spacing: 6) {
                            ForEach(column) { gif in
                                cell(gif)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func cell(_ gif: Gif) -> some View {
        Button {
            onSelect(gif)
            dismiss()
        } label: {
            AsyncImage(url: gif.previewURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.wispSurfaceVariant
            }
            // The real dimensions before load, so the grid never jumps.
            .aspectRatio(gif.width / max(gif.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
        .onAppear { model.cellAppeared(at: model.indexInPlaced(of: gif) ?? 0) }
        .accessibilityIdentifier("gif-cell")
    }
}
