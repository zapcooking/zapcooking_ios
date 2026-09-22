import SwiftUI

// MARK: - Render side (ALT badge + Description dialog)

/// The small dark "ALT" chip shown on images that carry an accessibility
/// description. Sighted users can inspect the text too — the badge is a
/// sibling tap target next to the image, never a nested control, so VoiceOver
/// gets two clean focus stops ("the description, image" / "View image
/// description").
struct AltBadge: View {
    var body: some View {
        Text("ALT")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
    }
}

/// The "Description" bottom sheet behind every ALT badge — a sheet, not an
/// alert, so long descriptions are fully readable (scrollable, expandable to
/// full height) instead of bouncing off the alert's size limit.
struct MediaAltDescriptionSheet: ViewModifier {
    let alt: String?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            AltDescriptionSheet(text: alt ?? "")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Sheet body: the full accessibility description, scrollable.
struct AltDescriptionSheet: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Description")
                    .font(.headline)
                Spacer()
                AltBadge()
            }
            ScrollView {
                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    func mediaAltDescriptionSheet(alt: String?, isPresented: Binding<Bool>) -> some View {
        modifier(MediaAltDescriptionSheet(alt: alt, isPresented: isPresented))
    }
}

/// Applies an accessibility label only when one exists — applying an empty
/// label would collapse the element to nothing for VoiceOver, so undescribed
/// media must keep its default behavior.
struct AltAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}

// MARK: - Compose side (alt-text editor)

/// Identifiable sheet payload: which attachment is being described, what to
/// preview, and the text to start from.
struct AltTextEditorTarget: Identifiable {
    /// The note composer's attachments identify by UUID; the sheet's own id.
    let attachmentID: UUID
    /// Recipe-compose images identify by Int, not UUID — carried through so
    /// the save closure can route the text back to the right image. Nil for
    /// note attachments, which is also the default so the note composer can
    /// omit it.
    var numericImageId: Int? = nil
    /// Uploaded URL for the preview when local bytes are gone.
    var previewURL: String?
    /// Pre-upload bytes — also what the AI generator sends when present.
    var localBytes: Data?
    var initialText: String?

    var id: UUID { attachmentID }
}

/// The alt-text editor behind the composer's "+ ALT / ✓ ALT" chip: image
/// preview, one-line explainer, a capped multiline field, Save/Clear, and the
/// Cook+ "Generate with AI" draft-fill action. Saving never blocks publishing
/// — alt text is optional metadata, and clearing the field removes the imeta
/// `alt` slot at publish time.
struct AltTextEditorView: View {
    let target: AltTextEditorTarget
    /// Signs the ask-photo request. Nil only from surfaces that disabled the
    /// AI action entirely.
    var keypair: Keypair?
    /// Called with the trimmed description, or nil when cleared.
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case generating
        case notice(String)
    }

    /// Hard cap matching the web composer — alt text is a description, not an
    /// essay; every client truncating at their own limit would be worse.
    static let maxCharacters = 2000

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                previewImage
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("A short description makes your photo accessible to screen reader users — and gives everyone context if the image doesn't load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .frame(minHeight: 96)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(remaining) remaining")
                            .font(.caption2)
                            .foregroundStyle(remaining < 100 ? .orange : .secondary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .onChange(of: text) { _, newValue in
                        if newValue.count > Self.maxCharacters {
                            text = String(newValue.prefix(Self.maxCharacters))
                        }
                    }

                aiSection

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { if text.isEmpty { text = target.initialText ?? "" } }
    }

    private var remaining: Int {
        max(0, Self.maxCharacters - text.count)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let bytes = target.localBytes, let img = UIImage(data: bytes) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else if let url = target.previewURL {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Color.wispSurfaceVariant
                }
            }
        } else {
            Color.wispSurfaceVariant
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// The Cook+ action. The generated text lands in the field as an editable
    /// draft — never applied to the attachment directly (the member reviews it
    /// first). Membership is enforced server-side; a denial renders
    /// message-only, no upsell link (build spec §4.3).
    @ViewBuilder
    private var aiSection: some View {
        if FeatureFlags.altTextAiEnabled, keypair != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    generateWithAI()
                } label: {
                    HStack(spacing: 6) {
                        if phase == .generating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Generate with AI")
                        Text("Cook+")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.wispPrimary.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.wispPrimary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(phase == .generating)
                .accessibilityLabel("Generate description with AI, Cook+ feature")

                if case .notice(let message) = phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func generateWithAI() {
        phase = .generating
        Task {
            let result = await AltTextGenerator.generate(
                previewURL: target.previewURL,
                localBytes: target.localBytes,
                keypair: keypair
            )
            apply(result)
        }
    }

    /// Map a service result onto editor state. Success never overwrites text
    /// the member already typed — it only fills an empty field, and the
    /// description stays an editable draft for review before Save.
    private func apply(_ result: AltTextServiceResult) {
        switch result {
        case .success(let description):
            phase = .idle
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = String(description.prefix(Self.maxCharacters))
            }
        case .notMember:
            phase = .notice("Cook+ members feature.")
        case .rateLimited:
            phase = .notice("Cheffy's swamped right now — try again a little later.")
        case .imageUnreadable:
            phase = .notice("Couldn't read that image. Try describing it manually.")
        case .tooLarge:
            phase = .notice("That image is too large for Cheffy. Try describing it manually.")
        case .notSignedIn:
            phase = .notice("Sign in with a signing key to use Cook+.")
        case .error(let message):
            phase = .notice(message)
        }
    }
}

/// Thin alias so tests and call sites don't reach into the service for the
/// result type.
typealias AltTextServiceResult = AltTextService.Result

/// Fetch-or-use-local bytes, then call the service. Static + injectable so
/// the editor stays a dumb view.
enum AltTextGenerator {
    static func generate(
        previewURL: String?,
        localBytes: Data?,
        keypair: Keypair?,
        service: AltTextService = AltTextService()
    ) async -> AltTextServiceResult {
        guard let keypair else { return .notSignedIn }
        let signer = LocalNip98Signer(keypair: keypair)
        let imageData: Data?
        if let localBytes, !localBytes.isEmpty {
            imageData = localBytes
        } else if let previewURL {
            // Post-upload the bytes are gone; fetch them back. Bounded GET —
            // a huge or lying body never buffers past the cap (the
            // RecipePublisher download path).
            imageData = await RecipePublisher.downloadCapped(
                url: previewURL,
                maxBytes: AltTextService.maxImageBytes,
                timeout: 20
            )?.0
        } else {
            imageData = nil
        }
        guard let imageData else { return .imageUnreadable }
        return await service.generateAlt(imageData: imageData, signer: signer)
    }
}
