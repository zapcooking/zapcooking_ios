import Foundation
import Observation

/// Backs ``RecipeComposeView`` — authoring a recipe from scratch (and
/// editing an existing one) and publishing it as a kind-30023 event via
/// the proven 2.3 spine (``RecipePublisher``).
///
/// Form fields mirror the web `/create` order and Android
/// `RecipeComposeViewModel`: title, categories, summary, chef's notes,
/// prep/cook/servings, ingredients, directions, photos, additional
/// resources. Images upload to Blossom **as they're picked**; publish is
/// blocked until every upload has resolved (no half-uploaded image can
/// be signed in). Validation returns the **reason** — the button shows
/// it; it is never a silent disable.
///
/// **Drafts stay out of NIP-37.** The fork's `DraftsViewModel` / kind-31234
/// machinery is a note composer (inner kind 1, `imeta` attachments, the
/// Drafts tab reopens `ComposeView`). A recipe is a structured form, not
/// a note; stuffing it into that pipeline would either lose fields or
/// teach the Drafts screen a second reopen path it does not have.
/// Android v1 is the same: state survives rotation, not process death;
/// persistence is a follow-up. Accidental dismiss is handled in the
/// view with a discard confirmation, not a relay-round-trip draft.
///
/// **Delete is not on this screen.** When an author-delete control lands
/// (Recipe detail, Concern 3.2 My Kitchen), it must call
/// `RecipeFeedViewModel.refresh()` after `RecipePublisher.delete` returns.
/// `RecipeRepository.ingest` drops non-recipes, so the blanked replacement
/// cannot evict the live coordinate — the card otherwise sits there
/// looking like the delete failed.
///
/// Port of Android `viewmodel/RecipeComposeViewModel.kt`.
@Observable
@MainActor
final class RecipeComposeViewModel {

    /// A single ingredient/direction row — stable `id` so SwiftUI identity
    /// survives edits/removals.
    struct Row: Identifiable, Equatable {
        var id: Int
        var text: String
    }

    /// A picked image and its Blossom upload status.
    struct ImageItem: Identifiable, Equatable {
        var id: Int
        var status: Status

        enum Status: Equatable {
            case uploading
            case done(url: String)
            case failed(message: String)
        }
    }

    enum PublishState: Equatable {
        case idle
        case publishing
        case error(String)
        case published(author: String, dTag: String)
    }

    /// Test/production seam. Production talks to Blossom. Tests inject
    /// hang/fail/success so the suite stays hermetic.
    struct Environment {
        var uploadImage: (Data, String, Keypair) async throws -> String
        var compressImage: (Data, String) -> (Data, String)
    }

    var title: String = ""
    var categories: [String] = []
    var summary: String = ""
    var chefNotes: String = ""
    var prepTime: String = ""
    var cookTime: String = ""
    var servings: String = ""
    var additionalResources: String = ""
    var ingredients: [Row] = [Row(id: 1, text: "")]
    var directions: [Row] = [Row(id: 2, text: "")]
    var images: [ImageItem] = []
    var publishState: PublishState = .idle
    var prefillNotice: String?
    var isEditing: Bool = false
    var editUnavailable: Bool = false

    /// True once a prefill (markdown / event / unavailable) has run.
    /// Further calls are no-ops so a re-entrant route cannot wipe edits.
    private var prefilled = false
    private var editing: NostrEvent?
    private var nextRowId = 3
    private let env: Environment
    @ObservationIgnored private var uploadTask: Task<Void, Never>?

    init(env: Environment? = nil) {
        self.env = env ?? .production
    }

    // MARK: - Categories

    func addCategory(_ raw: String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return }
        // De-dupe on the slugged form so "Italian" and "italian" don't both
        // add. slug() is locale-independent (web parity) — don't pre-lowercase
        // with the device locale (Turkish-i footgun).
        let slug = RecipeFormats.primary.slug(v)
        if categories.contains(where: { RecipeFormats.primary.slug($0) == slug }) { return }
        categories.append(v)
    }

    func removeCategory(_ value: String) {
        categories.removeAll { $0 == value }
    }

    // MARK: - Ingredient / direction rows

    func updateIngredient(id: Int, text: String) { updateRow(&ingredients, id: id, text: text) }
    func addIngredient() { addRow(&ingredients) }
    func removeIngredient(id: Int) { removeRow(&ingredients, id: id) }

    func updateDirection(id: Int, text: String) { updateRow(&directions, id: id, text: text) }
    func addDirection() { addRow(&directions) }
    func removeDirection(id: Int) { removeRow(&directions, id: id) }

    private func updateRow(_ rows: inout [Row], id: Int, text: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].text = text
    }

    private func addRow(_ rows: inout [Row]) {
        rows.append(Row(id: nextId(), text: ""))
    }

    private func removeRow(_ rows: inout [Row], id: Int) {
        rows.removeAll { $0.id == id }
        // Always keep at least one (empty) row so the field never disappears.
        if rows.isEmpty {
            rows = [Row(id: nextId(), text: "")]
        }
    }

    // MARK: - Prefill

    /// Seed the form from raw recipe markdown (Sous Chef / Cheffy "Save").
    /// Parses via the shared `RecipeParser.parseContent` and extracts the
    /// title from the first `# ` heading. **Leaves images, categories, and
    /// summary empty** (mirroring the web), so the user must add a photo +
    /// category before publish.
    ///
    /// Lossy-parse salvage: if the parse yields no ingredients/directions,
    /// the raw markdown is dropped into Additional Resources with empty
    /// rows and a notice — `blockReason` then stays active until the user
    /// fills the rows.
    func prefillFromMarkdown(_ markdown: String) {
        if prefilled { return }
        prefilled = true
        resetForm()

        let titleMatch = Self.titleHeading.firstMatch(
            in: markdown,
            range: NSRange(markdown.startIndex..., in: markdown)
        )
        if let titleMatch, let range = Range(titleMatch.range(at: 1), in: markdown) {
            let extracted = String(markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            title = extracted.isEmpty ? "Untitled" : extracted
        } else {
            title = "Untitled"
        }

        let parsed = RecipeParser.parseContent(markdown)
        let parseLooksGood = !parsed.ingredients.isEmpty && !parsed.directions.isEmpty
        if parseLooksGood {
            chefNotes = parsed.chefNotes ?? ""
            prepTime = parsed.details.prepTime ?? ""
            cookTime = parsed.details.cookTime ?? ""
            servings = parsed.details.servings ?? ""
            ingredients = parsed.ingredients.map { Row(id: nextId(), text: $0) }
            directions = parsed.directions.map { Row(id: nextId(), text: $0) }
            additionalResources = parsed.additionalMarkdown ?? ""
        } else {
            additionalResources = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            prefillNotice = "Couldn't parse that recipe cleanly — review the raw text in Additional Resources."
        }
    }

    /// Seed the form from an existing recipe event and put the screen in
    /// **edit** mode — `publish` then republishes at the same address.
    ///
    /// Photos arrive already hosted, so they go in as `.done`: nothing is
    /// re-uploaded. Returns false when the event is not a recipe this app
    /// can parse.
    @discardableResult
    func prefillFromEvent(_ event: NostrEvent) -> Bool {
        if prefilled { return editing != nil }
        guard let format = RecipeFormats.forEvent(event) else { return false }
        prefilled = true
        resetForm()
        let recipe = format.parse(event)
        editing = event
        isEditing = true

        title = recipe.title ?? ""
        summary = recipe.summary ?? ""
        categories = recipe.categories
        images = recipe.images
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ImageItem(id: nextId(), status: .done(url: $0)) }

        let c = recipe.content
        chefNotes = c.chefNotes ?? ""
        prepTime = c.details.prepTime ?? ""
        cookTime = c.details.cookTime ?? ""
        servings = c.details.servings ?? ""
        additionalResources = c.additionalMarkdown ?? ""
        ingredients = c.ingredients.map { Row(id: nextId(), text: $0) }
        if ingredients.isEmpty { ingredients = [Row(id: nextId(), text: "")] }
        directions = c.directions.map { Row(id: nextId(), text: $0) }
        if directions.isEmpty { directions = [Row(id: nextId(), text: "")] }
        return true
    }

    /// The editor was opened for a recipe that could not be loaded. Puts
    /// the screen in edit mode with publish blocked — a blank *create*
    /// form standing in for an edit would publish a second recipe.
    func markEditUnavailable() {
        prefilled = true
        isEditing = true
        editUnavailable = true
    }

    private func resetForm() {
        title = ""
        summary = ""
        chefNotes = ""
        prepTime = ""
        cookTime = ""
        servings = ""
        additionalResources = ""
        categories = []
        ingredients = [Row(id: nextId(), text: "")]
        directions = [Row(id: nextId(), text: "")]
        images = []
        prefillNotice = nil
    }

    // MARK: - Images

    /// Enqueue placeholders immediately (UI shows them + publish is
    /// blocked), then compress/upload sequentially. Never fans out N
    /// parallel Blossom uploads.
    func addImageBytes(_ items: [(Data, String)], keypair: Keypair) {
        guard !items.isEmpty else { return }
        let pending = items.map { (data, mime) -> (Int, Data, String) in
            (nextId(), data, mime)
        }
        images.append(contentsOf: pending.map { ImageItem(id: $0.0, status: .uploading) })
        let existing = uploadTask
        uploadTask = Task { [weak self] in
            await existing?.value
            for (id, data, mime) in pending {
                guard !Task.isCancelled else { return }
                await self?.uploadOne(id: id, data: data, mime: mime, keypair: keypair)
            }
        }
    }

    /// Load `NSItemProvider`s via ``MediaPicker``, then the same upload
    /// path. Placeholders go in first so a slow load still blocks publish.
    func addPickedProviders(_ providers: [NSItemProvider], keypair: Keypair) {
        guard !providers.isEmpty else { return }
        let pending = providers.map { (nextId(), $0) }
        images.append(contentsOf: pending.map { ImageItem(id: $0.0, status: .uploading) })
        let existing = uploadTask
        uploadTask = Task { [weak self] in
            await existing?.value
            for (id, provider) in pending {
                guard !Task.isCancelled else { return }
                let loaded = await MediaPicker.loadAll(providers: [provider])
                if let media = loaded.first {
                    await self?.uploadOne(id: id, data: media.data, mime: media.mime, keypair: keypair)
                } else {
                    self?.setImageStatus(id, .failed(message: "Couldn't read the selected image."))
                }
            }
        }
    }

    /// Test / edit helper: a URL that is already hosted (no upload).
    func addHostedImage(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        images.append(ImageItem(id: nextId(), status: .done(url: trimmed)))
    }

    func removeImage(id: Int) {
        images.removeAll { $0.id == id }
    }

    private func uploadOne(id: Int, data: Data, mime: String, keypair: Keypair) async {
        let status: ImageItem.Status
        do {
            let (bytes, outMime) = env.compressImage(data, mime)
            let url = try await env.uploadImage(bytes, outMime, keypair)
            status = .done(url: url)
        } catch is CancellationError {
            return
        } catch {
            status = .failed(message: error.localizedDescription.isEmpty ? "Upload failed" : error.localizedDescription)
        }
        setImageStatus(id, status)
    }

    private func setImageStatus(_ id: Int, _ status: ImageItem.Status) {
        guard let i = images.firstIndex(where: { $0.id == id }) else { return }
        images[i].status = status
    }

    // MARK: - Validation

    /// Why publish is blocked, or nil if ready. The UI puts this string
    /// **on the button** — never a greyed-out control with no explanation.
    func blockReason(canSign: Bool) -> String? {
        Self.blockReason(
            canSign: canSign,
            title: title,
            categories: categories,
            images: images,
            ingredients: ingredients,
            directions: directions,
            editUnavailable: editUnavailable
        )
    }

    /// Pure gate over plain values (mirrors the web `canPublish` + the
    /// upload-block guard). The UI and tests call this with snapshot state
    /// so the reason updates as fields fill in.
    static func blockReason(
        canSign: Bool,
        title: String,
        categories: [String],
        images: [ImageItem],
        ingredients: [Row],
        directions: [Row],
        editUnavailable: Bool = false
    ) -> String? {
        if editUnavailable {
            return "Couldn't load this recipe to edit. Go back and open it again."
        }
        if !canSign { return "Sign in to publish recipes." }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a title."
        }
        if categories.isEmpty { return "Add at least one category." }
        if images.isEmpty { return "Add at least one photo." }
        if images.contains(where: {
            if case .done = $0.status { return false }
            return true
        }) {
            return "Wait for photos to finish uploading (remove any that failed)."
        }
        if ingredients.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Add at least one ingredient."
        }
        if directions.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Add at least one direction."
        }
        return nil
    }

    /// Anything the user would lose on a back-swipe. Create: any typed
    /// field, chip, or photo. Edit: always — the form is a live recipe.
    var isDirty: Bool {
        if isEditing { return true }
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !categories.isEmpty { return true }
        if !images.isEmpty { return true }
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !chefNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !prepTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !cookTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !servings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !additionalResources.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if ingredients.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        if directions.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        return false
    }

    // MARK: - Publish

    /// Build the recipe from the form and publish via the multi-image
    /// ``RecipePublisher`` overload — or, in edit mode, republish as a
    /// replacement at the original address. Re-validates defensively.
    func publish(
        publisher: RecipePublisher,
        keypair: Keypair?,
        includeClientTag: Bool
    ) async {
        if publishState == .publishing { return }
        guard let keypair else {
            publishState = .error("Sign in to publish recipes.")
            return
        }
        if let reason = blockReason(canSign: true) {
            publishState = .error(reason)
            return
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageUrls = hostedImageURLs
        let categories = categories
        let original = editing
        let recipe = RecipeParser.Recipe(
            id: original?.id ?? "",
            author: keypair.pubkey,
            dTag: original.map { RecipeParser.dTag($0) } ?? RecipeFormats.primary.slug(title),
            title: title,
            images: imageUrls,
            summary: blankToNil(summary),
            publishedAt: original.map { RecipeParser.publishedAt($0) } ?? 0,
            hashtags: [],
            categories: categories,
            content: RecipeParser.RecipeContent(
                chefNotes: blankToNil(chefNotes),
                details: RecipeParser.RecipeDetails(
                    prepTime: blankToNil(prepTime),
                    cookTime: blankToNil(cookTime),
                    servings: blankToNil(servings)
                ),
                ingredients: clean(ingredients),
                directions: clean(directions),
                additionalMarkdown: blankToNil(additionalResources)
            )
        )
        publishState = .publishing
        do {
            let result: RecipePublisher.Result
            if let original {
                result = try await publisher.publishEdit(
                    original: original,
                    recipe: recipe,
                    categories: categories,
                    imageURLs: imageUrls,
                    keypair: keypair,
                    includeClientTag: includeClientTag
                )
            } else {
                result = try await publisher.publish(
                    recipe: recipe,
                    categories: categories,
                    imageURLs: imageUrls,
                    keypair: keypair,
                    includeClientTag: includeClientTag
                )
            }
            switch result {
            case .published(let author, let dTag, _, _, _):
                publishState = .published(author: author, dTag: dTag)
            case .error(let message):
                publishState = .error(message)
            }
        } catch is CancellationError {
            publishState = .idle
        } catch {
            publishState = .error(error.localizedDescription)
        }
    }

    var hostedImageURLs: [String] {
        images.compactMap {
            if case .done(let url) = $0.status { return url }
            return nil
        }
    }

    private func clean(_ rows: [Row]) -> [String] {
        rows.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func blankToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func nextId() -> Int {
        let id = nextRowId
        nextRowId += 1
        return id
    }

    /// First `# ` heading → recipe title (mirrors the web `extractRecipeTitle`).
    private static let titleHeading = try! NSRegularExpression(
        pattern: "^#\\s+(.+)$",
        options: .anchorsMatchLines
    )
}

extension RecipeComposeViewModel.Environment {
    static var production: RecipeComposeViewModel.Environment {
        RecipeComposeViewModel.Environment(
            uploadImage: { bytes, mime, keypair in
                var servers = BlossomServerList.cached(for: keypair.pubkey)
                if servers.isEmpty { servers = [BlossomServerList.defaultServer] }
                return try await BlossomClient.upload(
                    bytes: bytes,
                    mime: mime,
                    servers: servers,
                    keypair: keypair
                ).url
            },
            compressImage: { data, mime in
                let r = MediaCompressor.compressImage(data: data, mime: mime)
                return (r.data, r.mime)
            }
        )
    }
}
