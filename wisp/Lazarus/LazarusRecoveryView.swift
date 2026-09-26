import SwiftUI

/// Drawer → Settings → Data Recovery, and the Restore button on the user's
/// own profile. Owns the view model so the scan's sockets live exactly as
/// long as the sheet: pushing the review screen keeps them, dismissing the
/// sheet closes them.
struct LazarusRecoveryScreen: View {
    let keypair: Keypair
    var initialKind: Int = 3

    /// Built once, on appear: the presenting view re-runs this struct's
    /// initializer on every render, and the model derives key material.
    @State private var model: LazarusRecoveryViewModel?

    var body: some View {
        NavigationStack {
            if let model {
                LazarusRecoveryView(model: model)
                    .navigationDestination(item: Bindable(model).reviewingId) { _ in
                        LazarusReviewView(model: model)
                    }
            }
        }
        .interactiveDismissDisabled(model?.review?.status == .working)
        .onAppear {
            if model == nil { model = LazarusRecoveryViewModel(keypair: keypair, initialKind: initialKind) }
        }
        .onDisappear { model?.close() }
    }
}

struct LazarusRecoveryView: View {
    @Bindable var model: LazarusRecoveryViewModel

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var expandedFoundOn: Set<String> = []

    private var profile: LazarusKindProfile { model.profile }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                kindPicker
                kindNote
                scanControl
                if let published = model.published {
                    LazarusPublishedCard(summary: published, onScanAgain: {
                        model.dismissPublished()
                        model.startScan()
                    })
                } else if model.phase == .failed {
                    failedScan
                } else if model.phase == .done, let scan = model.scan {
                    results(scan)
                }
                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Data Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .disabled(model.review?.status == .working)
            }
        }
    }

    // MARK: - Header

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore a follow list, mute list, profile or other list that a client overwrote. Scanning asks your relays, and relays known to keep old versions, for every version that survives.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            Text("Nothing is restored without your tap, and every restore is signed by your own account.")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            if !model.canSign {
                LazarusNotice(text: "This account is view-only, so you can scan its history, but restoring needs a signing account.")
            }
        }
    }

    private var kindPicker: some View {
        FlowLayout(spacing: 8) {
            ForEach(model.kinds) { kind in
                let selected = kind.kind == model.selectedKind
                Button {
                    model.selectKind(kind.kind)
                } label: {
                    Text(kind.label)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? theme.primary : theme.palette.onSurfaceVariant)
                        .background(selected ? theme.subtleFill : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(selected ? theme.primary : theme.palette.outline.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("lazarus-kind-\(kind.kind)")
            }
        }
    }

    @ViewBuilder
    private var kindNote: some View {
        switch profile.kind {
        case 10002:
            LazarusNotice(text: "An old relay list can strand you on relays that no longer exist and silently break delivery of your posts. Check that a version's relays still work before restoring it.")
        case 10050:
            LazarusNotice(text: "An old DM relay list can point at inboxes that no longer exist, silently breaking delivery of your direct messages.")
        case 10044 where model.scan == nil:
            // Once versions are listed, the results say the same thing.
            LazarusNotice(text: "An empty encryption key list is a real choice: it announces that you don't use NIP-4e. Nothing is recommended here; you choose the version you intend.", style: .info)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scanControl: some View {
        if model.phase == .scanning {
            HStack(spacing: 10) {
                ProgressView()
                Text("Scanning relays for every version of your \(profile.name.lowercased())\u{2026}")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
        } else if model.published == nil {
            Button {
                model.startScan()
            } label: {
                Label(model.scan == nil ? "Scan relay history" : "Scan again", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)
            .accessibilityIdentifier("lazarus-scan")
        }
    }

    // MARK: - Failed scan

    private var failedScan: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazarusNotice(text: "No relay answered the scan, so nothing could be looked up. This isn't the same as having no history. Check your connection and scan again.", style: .error)
            if let scan = model.scan {
                relayOutcomes(scan)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ scan: LazarusScanResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            relayOutcomes(scan)
            notices(scan)
            if scan.candidates.isEmpty {
                Text("No versions found. The relays that answered hold no history of this list.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            } else {
                recommendation(scan)
                listToolbar(scan)
                ForEach(model.listItems) { item in
                    switch item {
                    case .version(let candidate):
                        row(candidate)
                    case .group(let candidates, let clobbered):
                        group(candidates, clobbered: clobbered, id: item.id)
                    }
                }
                olderVersions(scan)
            }
        }
    }

    private func relayOutcomes(_ scan: LazarusScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if model.phase == .done {
                    Text("\(scan.candidates.count) \(scan.candidates.count == 1 ? "version" : "versions") found \u{00B7}")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.palette.onSurface)
                }
                Button {
                    model.showRelayOutcomes.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("\(model.answeredRelayCount) of \(scan.queriedRelays.count) relays answered")
                        Image(systemName: model.showRelayOutcomes ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(theme.link)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lazarus-relay-outcomes")
            }
            if model.showRelayOutcomes {
                LazarusRelayOutcomeList(
                    relays: scan.queriedRelays,
                    outcomes: scan.relayOutcomes ?? [:],
                    writeRelays: Set(model.plan?.write ?? []),
                    writeAreStandIns: model.plan?.user.status == .missing
                )
            }
            let unreachable = model.unreachableRelays
            if model.phase == .done && !unreachable.isEmpty {
                Button {
                    model.retryUnreachable()
                } label: {
                    if model.retrying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Retrying\u{2026}")
                        }
                    } else {
                        Label("Retry \(unreachable.count) unreachable \(unreachable.count == 1 ? "relay" : "relays")",
                              systemImage: "arrow.clockwise")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .buttonStyle(.plain)
                .disabled(model.retrying || model.isBusy)
            }
        }
    }

    @ViewBuilder
    private func notices(_ scan: LazarusScanResult) -> some View {
        if Lazarus.reachedNoRelay(scan) {
            LazarusNotice(text: "No relay finished answering, so these versions may be incomplete. Scan again to retry.")
        } else if !scan.currentConfirmed {
            if scan.relayList == .unknown {
                LazarusNotice(text: "Your relay list couldn't be fetched, so the newest version found may not be current and nothing is recommended. Scan again to retry.")
            } else {
                LazarusNotice(text: "None of your write relays answered, so the newest version found may not be current and nothing is recommended. Retry the unreachable relays or scan again.")
            }
        }
        if scan.relayList == .missing {
            LazarusNotice(text: "No relay list found for this account, so the app's default relays stand in as its write relays: \(model.standIns.map(LazarusFormat.host).joined(separator: ", ")).", style: .info)
        }
        if scan.requiresIntentConfirmation && !scan.candidates.isEmpty {
            LazarusNotice(text: "An empty version can be intentional here, so nothing is recommended. Review the version you actually want.", style: .info)
        }
    }

    @ViewBuilder
    private func recommendation(_ scan: LazarusScanResult) -> some View {
        if let recommended = scan.recommended {
            VStack(alignment: .leading, spacing: 8) {
                Text("A sudden drop was detected. The recommended version is the fullest one from before the damage.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
                // Pinned here too, so a long history can't bury it inside a folded group.
                row(recommended)
            }
        } else if profile.ranking == .count && scan.currentConfirmed {
            Text("No recoverable improvement found. Your current version looks healthy; every version is listed below.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private func listToolbar(_ scan: LazarusScanResult) -> some View {
        if profile.ranking == .count && scan.candidates.count > 1 {
            HStack(spacing: 12) {
                Picker("Order", selection: $model.sortOrder) {
                    Text("Newest first").tag(LazarusSortOrder.date)
                    Text("Largest first").tag(LazarusSortOrder.size)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
            }
        }
        let pastEmpty = model.pastEmptyCount
        if pastEmpty > 0 {
            Button(model.showPastEmpty
                   ? "Hide empty versions"
                   : "Show \(pastEmpty) empty \(pastEmpty == 1 ? "version" : "versions")") {
                model.showPastEmpty.toggle()
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.link)
        }
    }

    @ViewBuilder
    private func olderVersions(_ scan: LazarusScanResult) -> some View {
        if !scan.olderCursors.isEmpty {
            Button {
                model.loadOlder()
            } label: {
                if model.loadingOlder {
                    HStack(spacing: 8) { ProgressView(); Text("Loading older versions\u{2026}") }
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Load older versions").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.loadingOlder)
        }
        if model.olderPageFailures > 0 {
            Text("\(model.olderPageFailures) \(model.olderPageFailures == 1 ? "relay" : "relays") didn't answer while loading older versions. Try again to page further back.")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
    }

    // MARK: - Rows

    private func group(_ candidates: [LazarusCandidate], clobbered: Bool, id: String) -> some View {
        let expanded = model.expandedGroups.contains(id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleGroup(id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: clobbered ? "exclamationmark.triangle.fill" : "square.stack")
                        .font(.system(size: 13))
                        .foregroundStyle(clobbered ? Color.orange : theme.palette.onSurfaceVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clobbered
                             ? "Sudden drop: \(candidates.count) versions"
                             : "Run of small edits: \(candidates.count) versions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(clobbered ? Color.orange : theme.palette.onSurface)
                        Text(LazarusFormat.groupSummary(candidates, profile: profile))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }
                .padding(12)
                .background(theme.palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(clobbered ? Color.orange.opacity(0.5) : theme.palette.outline.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(candidates) { candidate in
                    row(candidate).padding(.leading, 14)
                }
            }
        }
    }

    private func row(_ candidate: LazarusCandidate) -> some View {
        LazarusVersionRow(
            candidate: candidate,
            profile: profile,
            privateNote: privateNote(for: candidate),
            foundOnExpanded: expandedFoundOn.contains(candidate.id),
            onToggleFoundOn: {
                if expandedFoundOn.contains(candidate.id) {
                    expandedFoundOn.remove(candidate.id)
                } else {
                    expandedFoundOn.insert(candidate.id)
                }
            },
            onReview: model.canReview(candidate) ? { model.openReview(candidate) } : nil,
            reviewDisabled: model.isBusy
        )
    }

    private func privateNote(for candidate: LazarusCandidate) -> String? {
        guard LazarusPrivateItems.encryption(of: candidate.event.content) != nil,
              profile.privateItemTypes != nil else { return nil }
        if let decrypted = model.privateTags[candidate.id] {
            let count = LazarusPrivateItems.countItemTags(decrypted, types: profile.privateItemTypes ?? [])
            return count == 0 ? nil : "incl. \(count.formatted()) private"
        }
        if model.undecryptable.contains(candidate.id) { return "private items couldn't be decrypted" }
        return model.canSign ? nil : "private items estimated"
    }
}

// MARK: - Components

/// A warning, error or information line with an icon.
struct LazarusNotice: View {
    enum Style {
        case warning
        case error
        case info
    }

    let text: String
    var style: Style = .warning

    @Environment(\.theme) private var theme

    private var icon: String {
        switch style {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch style {
        case .warning: return .orange
        case .error: return .red
        case .info: return theme.palette.onSurfaceVariant
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style == .info ? theme.palette.surfaceVariant.opacity(0.5) : tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LazarusRelayOutcomeList: View {
    let relays: [String]
    let outcomes: [String: LazarusRelayOutcome]
    let writeRelays: Set<String>
    let writeAreStandIns: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(relays, id: \.self) { relay in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(outcomes[relay]))
                        .frame(width: 7, height: 7)
                    Text(LazarusFormat.host(relay))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.palette.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if writeRelays.contains(relay) {
                        Text(writeAreStandIns ? "default write" : "write")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.palette.surfaceVariant, in: Capsule())
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    Spacer(minLength: 4)
                    Text(LazarusFormat.outcome(outcomes[relay]))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }
            }
        }
        .padding(10)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func color(_ outcome: LazarusRelayOutcome?) -> Color {
        switch outcome {
        case .answered: return .green
        case .timedOut: return .orange
        case .failed, nil: return .red
        }
    }
}

struct LazarusVersionRow: View {
    let candidate: LazarusCandidate
    let profile: LazarusKindProfile
    let privateNote: String?
    let foundOnExpanded: Bool
    let onToggleFoundOn: () -> Void
    let onReview: (() -> Void)?
    let reviewDisabled: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(LazarusFormat.date(candidate.event.createdAt))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.palette.onSurface)
                        if candidate.isCurrent { badge("Current", fill: theme.palette.surfaceVariant, text: theme.palette.onSurfaceVariant) }
                        if candidate.isRecommended { badge("Recommended", fill: theme.primary, text: .white) }
                    }
                    Text(LazarusFormat.summary(candidate, profile: profile))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    if let privateNote {
                        Text(privateNote)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    if let detail = LazarusFormat.detail(candidate.event, profile: profile) {
                        Text(detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                            .lineLimit(4)
                    }
                    Button(action: onToggleFoundOn) {
                        Text("on \(candidate.foundOn.count) \(candidate.foundOn.count == 1 ? "relay" : "relays")")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.link)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let onReview {
                    Button("Review", action: onReview)
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.bordered)
                        .disabled(reviewDisabled)
                }
            }
            if foundOnExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidate.foundOn, id: \.self) { relay in
                        Text(LazarusFormat.host(relay))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(candidate.isRecommended ? theme.subtleFill : theme.palette.surface,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(candidate.isRecommended ? theme.primary : Color.clear, lineWidth: 1)
        )
    }

    private func badge(_ label: String, fill: Color, text: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
            .foregroundStyle(text)
    }
}

struct LazarusPublishedCard: View {
    let summary: LazarusPublishedSummary
    let onScanAgain: () -> Void

    @Environment(\.theme) private var theme

    private var report: LazarusPublishReport { summary.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Restored your \(summary.profile.name.lowercased())", systemImage: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
            Text("Accepted by \(report.accepted.count) of \(report.judgedOn.count) write \(report.judgedOn.count == 1 ? "relay" : "relays"): \(report.accepted.map(LazarusFormat.host).joined(separator: ", ")).")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            if !report.notAccepted.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Didn't accept it:")
                        .font(.system(size: 13, weight: .medium))
                    ForEach(report.notAccepted.map(\.relay), id: \.self) { relay in
                        Text("\(LazarusFormat.host(relay)): \(LazarusFormat.publishOutcome(report.outcomes[relay] ?? .failed))")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                }
            }
            if !report.bestEffort.isEmpty {
                Text("Also sent to \(report.bestEffort.count) other \(report.bestEffort.count == 1 ? "relay" : "relays") that answered the scan, so they stop serving the old version.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            if LazarusFormat.hasLocalCopy(summary.profile.kind) {
                Text("This app's copy was updated too, so your next edit here builds on the restored version.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            Button("Scan again", action: onScanAgain)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Formatting

/// Display strings for versions, relays and outcomes.
nonisolated enum LazarusFormat {
    static func date(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened)
    }

    static func shortDate(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .omitted)
    }

    /// `wss://relay.example.com` → `relay.example.com` (paths kept).
    static func host(_ relay: String) -> String {
        for prefix in ["wss://", "ws://"] where relay.hasPrefix(prefix) {
            return String(relay.dropFirst(prefix.count))
        }
        return relay
    }

    static func outcome(_ outcome: LazarusRelayOutcome?) -> String {
        switch outcome {
        case .answered: return "Answered"
        case .timedOut: return "Timed out"
        case .failed: return "Failed"
        case nil: return "Not asked"
        }
    }

    static func publishOutcome(_ outcome: LazarusPublishOutcome) -> String {
        switch outcome {
        case .accepted: return "accepted"
        case .rejected(let reason): return reason.isEmpty ? "rejected" : "rejected (\(reason))"
        case .failed: return "couldn't connect"
        case .timedOut: return "no answer"
        }
    }

    /// Whether this app keeps its own copy of the kind (see `LazarusLocalCopies`).
    static func hasLocalCopy(_ kind: Int) -> Bool {
        [0, 3, 10000, 10002, 10050, 10006].contains(kind)
    }

    /// "1,945 follows", "≈ 580–600 muted items (estimated)", "Empty".
    static func count(_ itemCount: LazarusItemCount, profile: LazarusKindProfile) -> String {
        let range = itemCount.range
        if itemCount.isSizeKnown && range.max == 0 {
            return profile.meaningfulEmpty ? "Empty: announces no NIP-4e keys" : "Empty"
        }
        guard itemCount.isSizeKnown else {
            return "\(profile.itemsLabel(itemCount.count)) public, private items uncounted"
        }
        if range.min == range.max { return profile.itemsLabel(range.min) }
        return "\u{2248} \(range.min.formatted())\u{2013}\(range.max.formatted()) \(profile.itemPlural) (estimated)"
    }

    static func summary(_ candidate: LazarusCandidate, profile: LazarusKindProfile) -> String {
        guard profile.kind == 0 else { return count(candidate.itemCount, profile: profile) }
        guard let data = candidate.event.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            return "Empty profile"
        }
        let name = [object["display_name"], object["name"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let fields = "\(object.count) \(object.count == 1 ? "field" : "fields")"
        return name.map { "\($0) \u{00B7} \(fields)" } ?? fields
    }

    /// Per-kind detail on a row: the keys of a NIP-4e list (the registry asks
    /// for them per version), the relays of a relay list.
    static func detail(_ event: NostrEvent, profile: LazarusKindProfile) -> String? {
        let values: [String]
        switch profile.kind {
        case 10044:
            values = event.tags.compactMap { $0.count >= 2 && $0[0] == "n" ? shortHex($0[1]) : nil }
        case 10002:
            values = event.tags.compactMap { tag in
                guard tag.count >= 2, tag[0] == "r" else { return nil }
                return tag.count >= 3 ? "\(host(tag[1])) (\(tag[2]))" : host(tag[1])
            }
        case 10050, 10006:
            values = event.tags.compactMap { $0.count >= 2 && $0[0] == "relay" ? host($0[1]) : nil }
        default:
            return nil
        }
        guard !values.isEmpty else { return nil }
        let shown = values.prefix(6).joined(separator: "\n")
        return values.count > 6 ? shown + "\n\u{2026}and \(values.count - 6) more" : shown
    }

    static func groupSummary(_ candidates: [LazarusCandidate], profile: LazarusKindProfile) -> String {
        let ranges = candidates.map(\.itemCount.range)
        let low = ranges.map(\.min).min() ?? 0
        let high = ranges.map(\.max).max() ?? 0
        let size = low == high ? profile.itemsLabel(low) : "\(low.formatted())\u{2013}\(high.formatted()) \(profile.itemPlural)"
        let newest = shortDate(candidates.first?.event.createdAt ?? 0)
        let oldest = shortDate(candidates.last?.event.createdAt ?? 0)
        return "\(size) \u{00B7} \(oldest == newest ? newest : "\(oldest) \u{2013} \(newest)")"
    }

    static func shortHex(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(8))\u{2026}\(hex.suffix(8))" : hex
    }

    /// One item of a delta, readably: accounts as npubs, relays by host.
    static func item(_ tag: [String]) -> String {
        guard let name = tag.first else { return "" }
        let value = tag.count >= 2 ? tag[1] : ""
        switch name {
        case "p": return Nip19.shortNpub(hex: value)
        case "e": return "note " + shortHex(value)
        case "a": return value
        case "word": return "\u{201C}\(value)\u{201D}"
        case "t": return "#\(value)"
        case "n": return "key " + shortHex(value)
        case "r": return tag.count >= 3 ? "\(host(value)) (\(tag[2]))" : host(value)
        case "relay": return host(value)
        default: return "\(name) \(value)"
        }
    }
}
