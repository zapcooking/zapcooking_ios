import SwiftUI

/// A user's agreement to the Terms of Service (App Review Guideline 1.2:
/// "require that users agree to terms (EULA) … no tolerance for
/// objectionable content or abusive users").
///
/// The agreement is given by tapping an action on an entry screen (splash,
/// or the account switcher's `LoginView`), beneath a line saying that
/// continuing is agreeing. It exists before any key does, and is then
/// carried down every sign-up and log-in path to `NostrKey.save`, which
/// takes it as a required
/// argument and records it for the pubkey before the key is written. That
/// is what makes "a key with no acceptance record" unreachable: there is no
/// way to save a key without handing over an acceptance, and the record
/// lands first.
///
/// Accounts that predate this step have no record and are not re-prompted.
nonisolated struct TermsAcceptance: Equatable, Sendable {
    /// The "Last updated" date of https://zap.cooking/terms at the time
    /// the in-app wording was written. Bump it when the terms change
    /// materially; a stored lower version is what a future re-prompt would
    /// key off.
    static let currentVersion = "2026-03-13"

    let version: String
    let acceptedAt: Date

    /// The acceptance given by tapping an entry action right now.
    static func now() -> TermsAcceptance {
        TermsAcceptance(version: currentVersion, acceptedAt: Date())
    }

    static func defaultsKey(for pubkey: String) -> String {
        "terms_accepted_\(pubkey)"
    }

    func record(for pubkey: String, in defaults: UserDefaults = .standard) {
        defaults.set(
            ["version": version, "acceptedAt": acceptedAt.timeIntervalSince1970],
            forKey: Self.defaultsKey(for: pubkey)
        )
    }

    static func load(pubkey: String, from defaults: UserDefaults = .standard) -> TermsAcceptance? {
        guard let dict = defaults.dictionary(forKey: defaultsKey(for: pubkey)),
              let version = dict["version"] as? String,
              let ts = dict["acceptedAt"] as? Double else { return nil }
        return TermsAcceptance(version: version, acceptedAt: Date(timeIntervalSince1970: ts))
    }
}

/// The line beneath the entry buttons on the splash and the account
/// switcher's `LoginView`. There is no checkbox: tapping the action is the
/// agreement, so each button hands `.now()` to its flow at the moment of the
/// tap. Terms and Privacy are links, opened in the system browser as About's
/// are.
struct TermsAgreementNotice: View {
    /// Text colour. The splash paints its own dark ground whatever the
    /// app's appearance, so it passes white; `LoginView` follows the theme.
    var textColor: Color = .wispOnSurfaceVariant
    var linkColor: Color = .wispPrimary

    var body: some View {
        Text(sentence)
            .font(.footnote)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("terms-agreement-notice")
    }

    private var sentence: AttributedString {
        var text = AttributedString("By continuing you agree to our ")
        text += link(PolicyLinks.termsOfService)
        text += AttributedString(" and ")
        text += link(PolicyLinks.privacyPolicy)
        text += AttributedString(". Zap Cooking has zero tolerance for objectionable content or abusive users.")
        return text
    }

    private func link(_ policy: PolicyLinks.Link) -> AttributedString {
        var part = AttributedString(policy.label)
        part.link = policy.url
        part.foregroundColor = linkColor
        part.underlineStyle = .single
        return part
    }
}
