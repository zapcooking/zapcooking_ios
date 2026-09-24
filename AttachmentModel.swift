import Foundation
import SwiftUI

/// Attachments that live outside the prose — the composer's media model.
///
/// An attachment is a slot on the draft, not text in the editor: `content`
/// never contains an attachment URL, `attachments` is the ordered and
/// authoritative array (its order is the only ordering that exists), and
/// two pure functions bridge the two at publish time. They are the entire
/// contract, kept here rather than in `ComposeViewModel` so every composer
/// surface calls the same code instead of each reimplementing it — anything
/// two composers both reimplement will diverge.
///
/// The wire format does not change: the URL in the content is still what
/// every client reads, and a note of bare URLs publishes byte-identical to
/// what it published before any of this existed.
enum AttachmentModel {

    // MARK: - Publish-time contract

    /// What the note says on the wire. Also what Preview shows, so the
    /// review window previews the note that will go out rather than the
    /// half the editor was showing. Prose first, then one URL per line,
    /// with a blank line between the two so the media block reads as its
    /// own paragraph in clients that don't render images inline.
    ///
    /// Media without a URL yet (upload in flight) contributes nothing —
    /// the caller is expected to gate publish on uploads finishing.
    static func composeNoteContent(text: String, media: [ComposeAttachment]) -> String {
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = media.compactMap { $0.url }.filter { !$0.isEmpty }
        guard !urls.isEmpty else { return prose }
        return (prose.isEmpty ? "" : prose + "\n\n") + urls.joined(separator: "\n")
    }

    /// One imeta tag per DESCRIBED attachment, in draft order. Undescribed
    /// media contributes nothing at all — the description follows its image
    /// through a reorder for free because the tags are generated from the
    /// same array, and there is no second structure to keep in step. The
    /// metadata we already know (`m`, `dim`, `x`, `duration`) rides along
    /// on described entries; the draft round-trip builder emits full
    /// metadata for every attachment regardless.
    ///
    /// The same URL may occupy more than one slot (attaching the same image
    /// twice is allowed; the note content carries its URL twice) — but one
    /// picture gets one tag, so tags are deduped by URL and the first
    /// described occurrence wins.
    static func imetaTags(for media: [ComposeAttachment]) -> [[String]] {
        var tagged = Set<String>()
        return media.compactMap { attachment in
            guard let url = attachment.url, !url.isEmpty else { return nil }
            let alt = normalizedAlt(attachment.altText ?? "")
            guard !alt.isEmpty else { return nil }
            guard tagged.insert(url).inserted else { return nil }
            return imetaEntries(url: url, alt: alt, attachment: attachment)
        }
    }

    /// The full-metadata imeta used by the NIP-37 draft save: one tag per
    /// uploaded attachment whether described or not, so reopening the draft
    /// restores the thumbnail row exactly. Mirrors `parseImetaAttachments`.
    static func draftImetaTags(for media: [ComposeAttachment]) -> [[String]] {
        media.compactMap { attachment in
            guard let url = attachment.url, !url.isEmpty else { return nil }
            return imetaEntries(url: url, alt: normalizedAlt(attachment.altText ?? ""), attachment: attachment)
        }
    }

    private static func imetaEntries(
        url: String,
        alt: String,
        attachment: ComposeAttachment
    ) -> [String] {
        var imeta: [String] = ["imeta", "url \(url)"]
        // Unknown mime — a pasted link whose metadata fetch hasn't finished
        // (or failed) — publishes without an `m` entry rather than lying.
        if !attachment.mime.isEmpty { imeta.append("m \(attachment.mime)") }
        if attachment.dim != .zero {
            imeta.append("dim \(Int(attachment.dim.width))x\(Int(attachment.dim.height))")
        }
        if let hash = attachment.sha256Hex { imeta.append("x \(hash)") }
        if let d = attachment.durationSec { imeta.append("duration \(d)") }
        // `alt` stays the last slot, matching what Amethyst/Quartz write.
        if !alt.isEmpty { imeta.append("alt \(alt)") }
        return imeta
    }

    // MARK: - Alt text

    /// Longest description we will emit or store.
    static let maxAltGraphemes = 2000

    /// Cap the description by grapheme clusters, not UTF-16 code units —
    /// `String.prefix` counts `Character`s, so a description ending in an
    /// emoji never ships half a surrogate pair the way a code-unit slice
    /// would. Line breaks become spaces (imeta entries are line-oriented)
    /// and the ends are trimmed, so a whitespace-only description counts
    /// as undescribed and emits nothing.
    static func normalizedAlt(_ source: String) -> String {
        let capped = String(source.prefix(maxAltGraphemes))
        return capped
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Non-empty normalized description, or nil — the shape the optional
    /// `alt` parameters of `Nip68.ImetaEntry` / `Nip71.VideoMeta` want.
    static func altOrNil(_ source: String) -> String? {
        let normalized = normalizedAlt(source)
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Paste-attach offers

    /// A single bare http(s) URL token: scheme, then no whitespace.
    static func isBareUrlToken(_ token: String) -> Bool {
        token.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func urlOnlyLineTokens(_ line: String) -> [String]? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy(isBareUrlToken) else { return nil }
        return tokens
    }

    /// Bare http(s) URLs offered as attachment slots: every URL occurrence
    /// on a line that contains ONLY URLs (whitespace-separated) — so a run
    /// of pasted links all surface, duplicates included (each accept
    /// consumes one occurrence), and accepting one leaves the rest as
    /// candidates on their own. A line with any non-URL word is authored
    /// prose and offers nothing.
    ///
    /// Deliberately more liberal than `stripBoundaryAttachmentLines`: the
    /// migration strip only takes exact single-URL lines because it guesses;
    /// this feeds an explicit user-tapped offer, so no guess is involved.
    /// Paste itself inserts text — the offer is the only thing that converts.
    static func attachableUrlCandidates(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let tokens = urlOnlyLineTokens(line) {
                out.append(contentsOf: tokens)
            }
        }
        return out
    }

    /// Remove the FIRST occurrence of `url` as a whitespace-delimited token
    /// on a URL-only line — the counterpart of accepting one offer. An
    /// emptied line is removed entirely so no blank line lingers; other
    /// tokens on the line stay. A URL on a line with any non-URL word is
    /// authored prose and is never touched. Returns the original text when
    /// there is no occurrence to consume (stale offer, fast double-tap).
    static func removeBareUrlOccurrence(_ text: String, url: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            guard let tokens = urlOnlyLineTokens(lines[i]),
                  let at = tokens.firstIndex(of: url) else { continue }
            var next = tokens
            next.remove(at: at)
            if next.isEmpty {
                lines.remove(at: i)
            } else {
                lines[i] = next.joined(separator: " ")
            }
            return lines.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Migration

    /// Drafts saved under the old model carry attachment URLs in their
    /// text. On restore, strip any line that is exactly an attachment's
    /// URL, or publishing appends it a second time.
    ///
    /// Only a **boundary occurrence** counts — the URL alone on its line.
    /// A URL a person deliberately wrote inside a sentence ("mirror at
    /// https://x/a.png if the first dies") is authored prose and survives.
    /// A URL twice on one line is ambiguous; leave it.
    static func stripBoundaryAttachmentLines(content: String, urls: [String]) -> String {
        let stripSet = Set(urls.filter { !$0.isEmpty })
        guard !stripSet.isEmpty else { return content }
        let lines = content.components(separatedBy: "\n").filter { line in
            !stripSet.contains(line.trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\n")
    }
}

/// Attachments that are no longer visible in the editor text need somewhere
/// to be accounted for: one collapsed card — paperclip, "N attachments,
/// added to the end of your post", trailing expand chevron — opening to one
/// row per URL. Android `AttachmentSummaryDrawer` placement: full-width
/// surface between the thumbnails and the actions row.
///
/// Read-only on purpose. The order it shows is the thumbnails' order, and
/// reordering belongs to the thumbnails — two places to change one array is
/// two places to keep in step and a race when both are open.
struct AttachmentSummaryDrawer: View {
    let media: [ComposeAttachment]
    @State private var expanded = false

    private var uploaded: [ComposeAttachment] {
        media.filter { attachment in
            guard let url = attachment.url else { return false }
            return !url.isEmpty
        }
    }

    var body: some View {
        if !uploaded.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(Self.summaryLine(count: uploaded.count))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.summaryLine(count: uploaded.count))
                .accessibilityHint(expanded ? "Collapses the attachment list" : "Expands the attachment list")

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(uploaded.enumerated()), id: \.element.id) { index, attachment in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.url ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let alt = attachment.trimmedAltText {
                                        Label(
                                            alt,
                                            systemImage: "text.bubble.fill"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    // Stretch to the card's leading edge: the card's
                    // VStack center-aligns children by default, and a
                    // content-sized block floated mid-card with the
                    // numbers dangling in an unexplained indent.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
        }
    }

    static func summaryLine(count: Int) -> String {
        count == 1
            ? "1 attachment, added to the end of your post"
            : "\(count) attachments, added to the end of your post"
    }
}
