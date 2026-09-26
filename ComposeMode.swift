import Foundation
import CoreGraphics

enum ComposeMode {
    case new
    case reply(parent: NostrEvent, root: NostrEvent?)
    case quote(NostrEvent)

    var allowsGalleryToggle: Bool {
        switch self {
        case .new: return true
        case .reply, .quote: return false
        }
    }

    /// Polls can be authored in `.new` and `.reply` contexts (Android allows both).
    /// Quote-as-poll is unsupported because the quote URL would push the poll question
    /// out of the visible content.
    var allowsPollToggle: Bool {
        switch self {
        case .new, .reply: return true
        case .quote: return false
        }
    }
}

/// Pending media awaiting upload or already-uploaded with metadata.
struct ComposeAttachment: Identifiable {
    let id: UUID
    /// Public Blossom URL once uploaded. Pre-upload it's nil.
    var url: String?
    let mime: String
    let dim: CGSize
    let durationSec: Int?
    let sha256Hex: String?
    /// Local copy of the bytes — kept around until upload completes so we can render
    /// a thumbnail. Cleared once `url` is set (video slots keep their poster
    /// frame: the remote .mp4 can't decode as a still).
    var localBytes: Data?
    /// Author-supplied accessibility description. Published as the NIP-92
    /// imeta `alt` slot (one imeta tag per described image — undescribed
    /// attachments emit no tag, never an empty one) and round-tripped
    /// through drafts. Because the description hangs off the same slot as
    /// the URL, it follows its image through a reorder for free.
    var altText: String? = nil

    var isVideo: Bool { mime.hasPrefix("video/") }

    /// The description as it should be written into the imeta `alt` slot:
    /// trimmed, empty collapsed to nil.
    var trimmedAltText: String? {
        guard let trimmed = altText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// A confirmed mention inserted into the composer text.
struct InsertedMention: Hashable {
    let displayName: String
    let pubkey: String
}
