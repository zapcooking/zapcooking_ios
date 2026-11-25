import Foundation

/// What the scheduled list needs from the scheduler API. `ScheduledPostsApi`
/// is the real thing (`ScheduleApi`); tests and the DEBUG harness stand in a
/// fake.
nonisolated protocol ScheduledListing: Sendable {
    func list(status: ScheduleStatus, keypair: Keypair) async -> Result<[ScheduledPost], ScheduleFailure>
    func cancel(id: String, keypair: Keypair) async -> Result<ScheduleCancellation, ScheduleFailure>
}

nonisolated struct ScheduledPostsApi: ScheduledListing {
    let session: URLSession

    @MainActor static var live: ScheduledPostsApi {
        ScheduledPostsApi(session: HttpClientFactory.generalClient)
    }

    func list(status: ScheduleStatus, keypair: Keypair) async -> Result<[ScheduledPost], ScheduleFailure> {
        await ScheduleApi.list(status: status, signer: LocalNip98Signer(keypair: keypair), session: session)
    }

    func cancel(id: String, keypair: Keypair) async -> Result<ScheduleCancellation, ScheduleFailure> {
        await ScheduleApi.cancel(id: id, signer: LocalNip98Signer(keypair: keypair), session: session)
    }
}

/// How the list is put in order, and what it says about a row. Pure, so the
/// rules have tests that need no screen.
nonisolated enum ScheduledList {

    /// Pending posts, next up first. The server sends newest publish time
    /// first; a person looking at "what's scheduled" wants the next one on top.
    static func pendingOrder(_ posts: [ScheduledPost]) -> [ScheduledPost] {
        posts.filter { $0.status == .pending }
            .sorted { ($0.publishAt, $0.id) < ($1.publishAt, $1.id) }
    }

    /// Failed posts, most recent first.
    static func failedOrder(_ posts: [ScheduledPost]) -> [ScheduledPost] {
        posts.filter { $0.status == .failed }
            .sorted { ($0.publishAt, $0.id) > ($1.publishAt, $1.id) }
    }

    /// The word on a row's status chip.
    static func statusLabel(for post: ScheduledPost, now: Int) -> String {
        switch post.status {
        case .failed: return "Didn't post"
        case .publishing: return "Posting now"
        case .sent: return "Posted"
        case .cancelled: return "Cancelled"
        case .pending:
            // A pending post past its time is waiting for the next sweep, or
            // for another try after a relay refused it.
            if post.attempts > 0 { return "Trying again" }
            return post.publishAt <= now ? "Posting soon" : "Scheduled"
        }
    }

    /// Plain words for a post that failed. The server's `last_error` is
    /// detail shown under this, never parsed and never the headline.
    static let failedExplanation =
        "This post wasn't published. The scheduler tried and has given up, so it won't go out. To post it, write it again."

    /// Shown when the pending list cannot be loaded.
    static func loadMessage(for failure: ScheduleFailure) -> String {
        switch failure {
        case .signedOut:
            return "Sign in with an account that can sign to see your scheduled posts."
        case .network:
            return "Couldn't reach Zap Cooking. Check your connection, then pull down to try again."
        case .authFailed, .notConfigured:
            return failure.message
        default:
            return "Couldn't load your scheduled posts. Pull down to try again."
        }
    }
}

/// What a scheduled row shows of its event, for every kind the scheduler
/// takes (the contract's "Kinds" table): the text, the first picture, a
/// poll's options, and a word for what kind of post it is.
nonisolated struct ScheduledPostPreview: Equatable, Sendable {
    /// "Poll", "Reply", "Picture"… nil for a plain note.
    let kindLabel: String?
    /// The text to show, media links taken out.
    let text: String
    /// The first picture, from the text or from an `imeta` tag.
    let imageUrl: String?
    /// How many pictures and videos there are beyond the first picture.
    let moreMediaCount: Int
    let hasVideo: Bool
    /// A poll's options, in order. Empty for anything else.
    let pollOptions: [String]

    init(event: NostrEvent) {
        let split = Self.splitMedia(event.content)
        var images = split.images
        var videos = split.videoCount
        // Pictures and videos (kinds 20, 21, 22) carry their media in imeta
        // tags, not in the text; notes carry both, the same URLs twice.
        for url in Self.imetaUrls(event.tags) where !images.contains(url) {
            switch Self.mediaType(ofUrl: url, mime: Self.imetaMime(event.tags, url: url)) {
            case .image: images.append(url)
            case .video: if !split.videoUrls.contains(url) { videos += 1 }
            case .other: break
            }
        }

        var text = split.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.kind {
        case Nip88.kindPoll:
            kindLabel = "Poll"
            pollOptions = Nip88.parsePollOptions(event).map(\.label)
        case Nip69.kindZapPoll:
            kindLabel = "Zap poll"
            pollOptions = Nip69.parseZapPollOptions(event).map(\.label)
        case Nip68.kindPicture:
            kindLabel = "Picture"
            pollOptions = []
        case Nip71.kindVideoHorizontal, Nip71.kindVideoVertical:
            kindLabel = "Video"
            pollOptions = []
        case 1111:
            kindLabel = "Comment"
            pollOptions = []
        case 30023:
            kindLabel = "Article"
            pollOptions = []
            // An article's body is long markdown; its title says what it is.
            if let title = event.tags.first(where: { $0.count >= 2 && $0[0] == "title" })?[1],
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = title
            }
        default:
            let isReply = event.tags.contains { $0.count >= 2 && $0[0] == "e" && !($0.count >= 4 && $0[3] == "mention") }
            kindLabel = isReply ? "Reply" : nil
            pollOptions = []
        }

        self.text = text
        imageUrl = images.first
        hasVideo = videos > 0
        moreMediaCount = max(0, images.count - 1) + videos
    }

    // MARK: - Media

    private enum MediaType { case image, video, other }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m3u8"]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "ogg", "m4a", "flac", "aac"]

    private static func mediaType(ofUrl url: String, mime: String?) -> MediaType {
        if let mime = mime?.lowercased() {
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("video/") { return .video }
        }
        let path = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
        let ext = (path as NSString).pathExtension
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return .other
    }

    /// Take media links out of the text: pictures are collected, videos and
    /// audio are counted and dropped (the row says "video" on its own line).
    /// The same link pattern the drafts row uses.
    private static func splitMedia(_ content: String) -> (text: String, images: [String], videoUrls: [String], videoCount: Int) {
        let all = imageExtensions.union(videoExtensions).union(audioExtensions).sorted().joined(separator: "|")
        let pattern = "https?://\\S+\\.(?:\(all))(?:\\?\\S*)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (content, [], [], 0)
        }
        let ns = content as NSString
        var text = ""
        var images: [String] = []
        var videoUrls: [String] = []
        var lastEnd = 0
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let url = ns.substring(with: match.range)
            switch mediaType(ofUrl: url, mime: nil) {
            case .image: if !images.contains(url) { images.append(url) }
            case .video: if !videoUrls.contains(url) { videoUrls.append(url) }
            case .other: break
            }
            lastEnd = match.range.upperBound
        }
        text += ns.substring(from: lastEnd)
        return (text, images, videoUrls, videoUrls.count)
    }

    /// `["imeta", "url https://…", "m image/jpeg", …]` → the URLs, in order.
    private static func imetaUrls(_ tags: [[String]]) -> [String] {
        tags.compactMap { tag in
            guard tag.first == "imeta" else { return nil }
            return tag.dropFirst().first(where: { $0.hasPrefix("url ") }).map { String($0.dropFirst(4)) }
        }
    }

    private static func imetaMime(_ tags: [[String]], url: String) -> String? {
        for tag in tags where tag.first == "imeta" && tag.contains("url \(url)") {
            if let m = tag.dropFirst().first(where: { $0.hasPrefix("m ") }) { return String(m.dropFirst(2)) }
        }
        return nil
    }
}
