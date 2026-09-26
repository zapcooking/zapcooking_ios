import SwiftUI

/// The review before a restore (spec "The delta rule"): what the restore
/// adds and removes, the direction of harm, the intent question for
/// meaningful-empty kinds, and a restore button that names what it
/// publishes. A shrinking restore needs a separate confirmation; a restore
/// whose current version couldn't be confirmed stops, offers a retry, and
/// only after that retry fails offers an explicit override.
struct LazarusReviewView: View {
    @Bindable var model: LazarusRecoveryViewModel

    @Environment(\.theme) private var theme

    private var profile: LazarusKindProfile { model.profile }
    private var isWorking: Bool { model.review?.status == .working }

    var body: some View {
        ScrollView {
            if let review = model.review, let candidate = model.reviewCandidate {
                VStack(alignment: .leading, spacing: 18) {
                    header(candidate, review: review)
                    if review.changedSinceReview {
                        LazarusNotice(text: "Your \(profile.name.lowercased()) changed after the scan (another device or client edited it). The changes below now compare against that newer version. Check them and confirm again.")
                    }
                    changes(candidate, review: review)
                    warnings(review)
                    if profile.meaningfulEmpty {
                        intentQuestion(candidate, review: review)
                    }
                    targets
                    actions(candidate, review: review)
                }
                .padding(20)
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Review Restore")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
    }

    // MARK: - Header

    private func header(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore your \(profile.name.lowercased()) from \(LazarusFormat.date(candidate.event.createdAt))?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.palette.onSurface)
            Text(LazarusFormat.summary(candidate, profile: profile))
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            Text(comparisonLine(review))
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            Text("Restoring republishes this version as a new event signed by your account, replacing the current one everywhere it's accepted.")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
    }

    private func comparisonLine(_ review: LazarusReview) -> String {
        guard let current = review.reviewedCurrent else {
            return "No current version was found to compare against."
        }
        let source = LazarusLocalCopies.isLocalCopy(current) ? " (this device's copy)" : ""
        return "Compared with your current version from \(LazarusFormat.date(current.createdAt))\(source)."
    }

    // MARK: - Changes

    @ViewBuilder
    private func changes(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        if let fieldChanges = review.profileChanges {
            section("What changes") {
                if fieldChanges.isEmpty {
                    Text("No profile fields or tags would change.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    ForEach(fieldChanges, id: \.field) { change in
                        profileChange(change)
                    }
                }
            }
        } else if let delta = review.delta {
            section("What changes") {
                HStack(spacing: 14) {
                    Text("+\(delta.addedCount.formatted()) added")
                        .foregroundStyle(.green)
                    Text("\u{2212}\(delta.removedCount.formatted()) removed")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 15, weight: .semibold))
                if delta.privateUnknown {
                    LazarusNotice(text: privateUnknownText, style: .info)
                }
                if !delta.added.isEmpty {
                    LazarusItemList(title: addedTitle(delta.addedCount), items: delta.added)
                }
                if !delta.removed.isEmpty {
                    LazarusItemList(title: removedTitle(delta.removedCount), items: delta.removed)
                }
            }
        }
    }

    private var privateUnknownText: String {
        model.canSign
            ? "Some private items are encrypted and couldn't be decrypted, so they're uncounted here. They restore exactly as they were."
            : "Private items are encrypted and a view-only account can't decrypt them, so they're uncounted here. They restore exactly as they were."
    }

    private func addedTitle(_ n: Int) -> String {
        switch profile.kind {
        case 3: return "Would be followed again (\(n.formatted()))"
        case 10000: return "Would be muted again (\(n.formatted()))"
        default: return "Added (\(n.formatted()))"
        }
    }

    private func removedTitle(_ n: Int) -> String {
        switch profile.kind {
        case 3: return "Would be unfollowed (\(n.formatted()))"
        case 10000: return "Would be unmuted (\(n.formatted()))"
        default: return "Removed (\(n.formatted()))"
        }
    }

    private func profileChange(_ change: LazarusProfileChange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(change.field)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            if let to = change.to {
                Text(to)
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                    .lineLimit(6)
            } else {
                Text("removed")
                    .font(.system(size: 14).italic())
                    .foregroundStyle(.red)
            }
            if let from = change.from {
                Text(from)
                    .font(.system(size: 13))
                    .strikethrough()
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Warnings

    @ViewBuilder
    private func warnings(_ review: LazarusReview) -> some View {
        if profile.requiredWarnings.contains(.remute), let delta = review.delta {
            if delta.addedCount > 0 {
                LazarusNotice(text: "This restore re-mutes \(delta.addedCount.formatted()) \(delta.addedCount == 1 ? "item" : "items") (accounts, words, hashtags or threads) you may have unmuted on purpose since. That's a moderation action taken on your behalf.")
            }
            if delta.removedCount > 0 {
                LazarusNotice(text: "\(delta.removedCount.formatted()) \(delta.removedCount == 1 ? "item" : "items") muted now \(delta.removedCount == 1 ? "isn't" : "aren't") in this version and would be unmuted.", style: .info)
            }
        }
        if profile.requiredWarnings.contains(.staleRelays) {
            LazarusNotice(text: "An old relay list can point at relays that no longer exist, stranding you and silently breaking delivery. Make sure the relays in this version still work.")
        }
        if profile.kind == 10000, let candidate = model.reviewCandidate, model.undecryptable.contains(candidate.id) {
            LazarusNotice(text: "This app can't read this version's private items, so a later mute or block made in this app would drop them.", style: .info)
        }
    }

    // MARK: - Intent (meaningful-empty kinds)

    private func intentQuestion(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        let restoringEmpty = candidate.itemCount.range.max == 0
        let currentEmpty = review.reviewedCurrent.map { profile.itemCount($0).range.max == 0 } ?? true
        let restoreMeaning = restoringEmpty
            ? "This restores the empty state, which announces that you don't use NIP-4e. Clients will stop encrypting direct messages to your listed keys."
            : "This restores your NIP-4e encryption keys. Clients will encrypt direct messages to them again."
        let currentMeaning = currentEmpty
            ? "The current empty state announces that you don't use NIP-4e."
            : "Your current list names \(profile.itemsLabel(review.reviewedCurrent.map { profile.itemCount($0).count } ?? 0)), which clients use now."
        return section("Is this what you intend?") {
            Text(restoreMeaning)
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            Text(currentMeaning)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            Toggle("I intend this change", isOn: Binding(
                get: { model.review?.intentConfirmed ?? false },
                set: { model.setIntentConfirmed($0) }
            ))
            .font(.system(size: 14, weight: .medium))
            .disabled(isWorking)
            .accessibilityIdentifier("lazarus-intent")
        }
    }

    // MARK: - Targets

    @ViewBuilder
    private var targets: some View {
        if let targets = model.reviewTargets {
            if targets.judged.isEmpty {
                LazarusNotice(text: "Your relay list couldn't be fetched, so there are no write relays to publish to or confirm the current version on. Go back and scan again when your connection is back.", style: .error)
            } else {
                let standIns = model.plan?.user.status == .missing && profile.kind != 10002
                let label = profile.kind == 10002
                    ? "Success is judged on the write relays this version names"
                    : (standIns ? "Publishes to the app's default relays (you have no relay list)" : "Publishes to your write relays")
                Text("\(label): \(targets.judged.map(LazarusFormat.host).joined(separator: ", "))."
                     + (targets.extra.isEmpty ? "" : " \(targets.extra.count) other \(targets.extra.count == 1 ? "relay gets" : "relays get") a copy too, so \(targets.extra.count == 1 ? "it stops" : "they stop") serving the old version."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        if !model.canSign {
            LazarusNotice(text: "This account is view-only. You can review its history, but restoring needs a signing account.", style: .info)
        } else if model.reviewTargets?.judged.isEmpty ?? true {
            EmptyView()
        } else {
            switch review.status {
            case .working:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Confirming your current version, then signing and publishing\u{2026}")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }
            case .unconfirmed:
                unconfirmed(candidate, review: review)
            case .failed(let message):
                failed(message, candidate: candidate, review: review)
            case .ready:
                restoreControls(candidate, review: review)
            }
        }
    }

    private func canRestore(_ review: LazarusReview) -> Bool {
        !profile.meaningfulEmpty || review.intentConfirmed
    }

    /// Single-line action buttons, matching the Android screen. The version
    /// each one publishes is named in the header above, never on the button.
    @ViewBuilder
    private func restoreControls(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        if let delta = review.delta, delta.shrinks {
            if review.shrinkArmed {
                VStack(alignment: .leading, spacing: 10) {
                    LazarusNotice(text: "This restore shrinks your \(profile.name.lowercased()) below the current version: it removes \(profile.itemsLabel(delta.removedCount)) you have now and adds \(delta.addedCount.formatted()).", style: .error)
                    Button(role: .destructive) {
                        model.restore()
                    } label: {
                        Text("Confirm removal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(!canRestore(review))
                    .accessibilityIdentifier("lazarus-confirm-shrink")
                    Button("Cancel") { model.armShrinkConfirmation(false) }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    model.armShrinkConfirmation(true)
                } label: {
                    Text("Continue: this removes \(profile.itemsLabel(delta.removedCount))")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRestore(review))
                .accessibilityIdentifier("lazarus-restore")
            }
        } else {
            Button {
                model.restore()
            } label: {
                Text("Restore this version").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRestore(review))
            .accessibilityIdentifier("lazarus-restore")
        }
    }

    private func unconfirmed(_ candidate: LazarusCandidate, review: LazarusReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazarusNotice(text: "None of your write relays answered, so your current version couldn't be confirmed and nothing was published. Try again: a newer version there would otherwise be overwritten.", style: .error)
            Button {
                model.restore()
            } label: {
                Text("Retry the restore").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canRestore(review))
            if review.overrideOffered {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Retrying didn't help. You can restore without confirming the current version, for example when your relay list names only relays that are gone. Edits made since the review, on any device or client, may be lost.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurface)
                    Toggle("I intend this, knowing edits made since the review may be lost", isOn: Binding(
                        get: { model.review?.overrideConfirmed ?? false },
                        set: { model.setOverrideConfirmed($0) }
                    ))
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityIdentifier("lazarus-override")
                    Button(role: .destructive) {
                        model.restore(override: true)
                    } label: {
                        Text("Restore anyway").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(!review.overrideConfirmed || !canRestore(review))
                }
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func failed(_ message: String, candidate: LazarusCandidate, review: LazarusReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazarusNotice(text: message, style: .error)
            if let report = review.rejectedReport {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.judgedOn, id: \.self) { relay in
                        Text("\(LazarusFormat.host(relay)): \(LazarusFormat.publishOutcome(report.outcomes[relay] ?? .failed))")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                }
            }
            Button {
                model.restore()
            } label: {
                Text("Retry the restore").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canRestore(review))
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// A collapsible list of the items a restore adds or removes.
struct LazarusItemList: View {
    let title: String
    let items: [[String]]

    @Environment(\.theme) private var theme
    @State private var expanded = false

    private static let shownLimit = 100

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.prefix(Self.shownLimit).enumerated()), id: \.offset) { _, tag in
                    Text(LazarusFormat.item(tag))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if items.count > Self.shownLimit {
                    Text("\u{2026}and \((items.count - Self.shownLimit).formatted()) more")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.palette.onSurface)
        }
    }
}
