import SwiftUI

/// Policy pages the app must link to from inside the app (build spec §4.4 /
/// Phase 4 item 4.3): privacy policy and child-safety standards for App
/// Review, terms alongside them. Mirrors Android's `AboutScreen.PolicyLinks`
/// — same origin, same paths, same labels — so the two apps point reviewers
/// at the same documents.
///
/// Account deletion (4.2) is deliberately not in this list yet: the Android
/// entry links to an email-request page, and Apple's account-deletion
/// guidance does not accept an email flow outside regulated industries. It
/// joins this list once the deletion approach is decided.
nonisolated enum PolicyLinks {
    static let origin = "https://zap.cooking"

    struct Link: Equatable, Sendable {
        let label: String
        let url: URL
    }

    static let privacyPolicy = Link(label: "Privacy Policy", url: URL(string: "\(origin)/privacy")!)
    static let termsOfService = Link(label: "Terms of Service", url: URL(string: "\(origin)/terms")!)
    static let childSafety = Link(label: "Child Safety Standards", url: URL(string: "\(origin)/child-safety")!)

    /// Display order on the About screen.
    static let all: [Link] = [privacyPolicy, termsOfService, childSafety]
}

/// Drawer → Settings → About. Policies open in the system browser (the
/// Android screen uses `ACTION_VIEW` for the same reason: these are public
/// web pages, and a `WKWebView` carrying them would be one more web surface
/// for a Guideline 4.2 reviewer to weigh).
struct AboutView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: "Policies") {
                    ForEach(Array(PolicyLinks.all.enumerated()), id: \.offset) { index, link in
                        if index > 0 {
                            Divider().overlay(theme.palette.surfaceVariant)
                        }
                        policyRow(link)
                    }
                }

                Text(versionString)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policyRow(_ link: PolicyLinks.Link) -> some View {
        Button {
            openURL(link.url)
        } label: {
            HStack {
                Text(link.label)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.palette.onSurface)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("policy-link-\(link.url.lastPathComponent)")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Zap Cooking \(version) (\(build))"
    }
}
