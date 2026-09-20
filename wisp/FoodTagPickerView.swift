import SwiftUI

/// The full food-tag set behind the composer row's "+": every tag the
/// OnlyFood filter matches on (`FoodHashtags.all`, 85), "Popular" first
/// (the eight pills), then the rest alphabetically, with a search field.
///
/// Why this set and this shape:
/// - `FoodHashtags`, not `FoodTopics`: a tag from this list is what makes a
///   note reachable in OnlyFood. The taxonomy normalises to 108 tags of
///   which 66 (bread, cheese, chocolate…) would dead-end, and 43 of the 85
///   filter tags appear in no section, so grouping under its sections is
///   not possible without inventing half of them.
/// - A sheet (medium detent, expandable), not inline expansion: every
///   other picker in this composer already resigns the keyboard and
///   presents a modal, and at 375pt inline chips would push the toolbar
///   and Publish off screen.
/// - Taps go through the same `toggleSuggestedHashtag` as the row, so the
///   body stays the single source of truth and the cap applies.
struct FoodTagPickerView: View {
    @Bindable var viewModel: ComposeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    static let title = "Food tags"
    static let hint = "Any of these puts the note in OnlyFood."

    private var popular: [String] { OnlyFoodCompose.pickerMatches(OnlyFoodCompose.pickerPopular, query: query) }
    private var rest: [String] { OnlyFoodCompose.pickerMatches(OnlyFoodCompose.pickerRest, query: query) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        countLabel
                    }

                    searchField

                    if popular.isEmpty && rest.isEmpty {
                        Text("No food tag matches “\(query.trimmingCharacters(in: .whitespaces))”. You can still type it in the note, but it won't reach OnlyFood.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag-picker-empty")
                    }
                    if !popular.isEmpty {
                        section("Popular", tags: popular)
                    }
                    if !rest.isEmpty {
                        section("All food tags", tags: rest)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tag-picker-done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tag-picker")
    }

    private var countLabel: some View {
        let count = viewModel.suggestedTagCount
        return Text("\(count)/\(OnlyFoodCompose.maxTags) tags")
            .font(.caption.monospacedDigit())
            .foregroundStyle(viewModel.suggestedTagsOverCap ? Color.red : Color.secondary)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tags", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .accessibilityIdentifier("tag-picker-search")
            if !query.isEmpty {
                Button {
                    query = ""
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

    private func section(_ title: String, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            FlowLayout(spacing: HashtagPillMetrics.spacing) {
                ForEach(tags, id: \.self) { tag in
                    let selected = viewModel.isSuggestedHashtagSelected(tag)
                    HashtagChip(tag: tag, selected: selected, blocked: !selected && viewModel.suggestedTagsAtCap) {
                        viewModel.toggleSuggestedHashtag(tag)
                    }
                    .accessibilityIdentifier("picker-pill-\(tag)")
                }
            }
        }
    }
}
