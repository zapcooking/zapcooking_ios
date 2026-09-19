import SwiftUI

/// Tappable hashtag suggestions under the composer (OnlyFood, Concern:
/// tag-suggestion pills). A pill is selected when its tag is in the
/// composer's derived hashtags, whatever put it there; tapping toggles the
/// tag in the body through the view model. At the structural cap, unselected
/// pills are disabled; the count reads exactly as `OnlyFoodFilter` counts.
struct HashtagSuggestionRow: View {
    @Bindable var viewModel: ComposeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(OnlyFoodCompose.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                countLabel
            }
            FlowLayout(spacing: 8) {
                ForEach(viewModel.suggestedHashtags, id: \.self) { tag in
                    pill(tag)
                }
            }
            if viewModel.suggestedTagsOverCap {
                Text("OnlyFood hides notes with more than \(OnlyFoodCompose.maxTags) tags.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("tag-over-cap")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tag-suggestions")
    }

    private var countLabel: some View {
        let count = viewModel.suggestedTagCount
        return Text("\(count)/\(OnlyFoodCompose.maxTags) tags")
            .font(.caption.monospacedDigit())
            .foregroundStyle(viewModel.suggestedTagsOverCap ? Color.red : Color.secondary)
            .accessibilityIdentifier("tag-count")
    }

    private func pill(_ tag: String) -> some View {
        let selected = viewModel.isSuggestedHashtagSelected(tag)
        let blocked = !selected && viewModel.suggestedTagsAtCap
        return Button {
            viewModel.toggleSuggestedHashtag(tag)
        } label: {
            Text("#\(tag)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.wispPrimary : Color.wispSurfaceVariant.opacity(0.6),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.white : Color.wispPrimary)
                .opacity(blocked ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityLabel("#\(tag)")
        .accessibilityValue(selected ? "added" : (blocked ? "tag limit reached" : "not added"))
        .accessibilityIdentifier("tag-pill-\(tag)")
    }
}
