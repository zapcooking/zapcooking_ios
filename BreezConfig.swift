import Foundation

/// Reads the Breez Spark API key from a bundled resource file.
/// Drop your key (one line) into `wisp/Resources/breez-api-key.txt` (gitignored).
enum BreezConfig {
    static let apiKey: String = {
        guard let url = Bundle.main.url(forResource: "breez-api-key", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static var hasApiKey: Bool { !apiKey.isEmpty }

    /// Domain Lightning addresses are registered under. `sats.zap.cooking`
    /// is a CNAME to Breez's hosted LNURL server (breez.tips), registered
    /// with Breez against this API key — the same setup the web app uses.
    /// Passed to the SDK as `config.lnurlDomain` at connect time.
    static let lnurlDomain = "sats.zap.cooking"

    /// Spark's USDB stablecoin — the asset behind the wallet's opt-in USD
    /// balance. The identifier is the token's own on-network id and is the
    /// same value the web and Android clients use, so a seed shared across
    /// devices lands on the same token.
    static let usdTokenIdentifier =
        "btkn1xgrvjwey5ngcagvap2dzzvsy4uk8ua9x69k82dwvt5e7ef9drm9qztux87"

    /// Label the SDK keys the stable balance under. Written into
    /// `StableBalanceConfig` at connect and read back off
    /// `UserSettings.stableBalanceActiveLabel` to tell whether the user
    /// has USD mode on.
    static let usdBalanceLabel = "USDB"

    /// Pinned Breez Spark SDK version, mirrored from
    /// `wisp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
    /// Update this string whenever the SDK is bumped — there's no runtime
    /// version constant exposed by the Swift bindings to read instead.
    static let sdkVersion = "0.28.1"
}
