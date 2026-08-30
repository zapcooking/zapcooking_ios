import Foundation

/// Dev / e2e / live-gate recipes that must not surface in the Recipes tab,
/// tag feeds, detail, or search.
///
/// Two matchers, one object — do not invent a second hide list:
///
/// 1. **Exact NIP-01 coordinates** `kind:pubkey:d-tag` (not event ids), so a
///    later replaceable revision of a known test recipe stays hidden.
/// 2. **d-tag prefixes**, so a live-write gate that mints a fresh ephemeral
///    key per run cannot outgrow an enumerated pubkey denylist. The 2.3
///    probes all share `ios-2.3-live-publish-`; only the trailing timestamp
///    differs.
///
/// Applied in `RecipeRepository` (`deduped` / `requestRecipe` / `cached`) so
/// every consumer inherits one reduction. Do not re-filter in views.
///
/// **This list is duplicated.** There is no shared package iOS, Android, and
/// web read. Keep `coordinates` in lockstep with Android `HiddenRecipes.kt`
/// and web `HIDDEN_RECIPE_COORDINATES` (`src/lib/consts.ts`); keep
/// `dTagPrefixes` in lockstep with the same two files. Drift here is a
/// recipe that is hidden on one platform and a card on another.
nonisolated enum HiddenRecipes {

    /// Same 19 coordinates as Android `HiddenRecipes.COORDINATES` and web
    /// `HIDDEN_RECIPE_COORDINATES`.
    static let coordinates: Set<String> = [
        "30023:8b739c62ed2a9b76c2836a18a6bc9a480b6f8d902b8f702083dfae20bf6b15b9:zc-pr11-test-bravo",
        "30023:8b739c62ed2a9b76c2836a18a6bc9a480b6f8d902b8f702083dfae20bf6b15b9:zc-pr11-test-alpha",
        "30023:8b739c62ed2a9b76c2836a18a6bc9a480b6f8d902b8f702083dfae20bf6b15b9:pr10-pancakes",
        "30023:a22a71c97b536902adb2b15f3e56014d2a2a2adc0c2d99f3996081455cc4ea92:pr11-ghost-recipe",
        "30023:a22a71c97b536902adb2b15f3e56014d2a2a2adc0c2d99f3996081455cc4ea92:pr10-zero-parse2",
        "30023:a22a71c97b536902adb2b15f3e56014d2a2a2adc0c2d99f3996081455cc4ea92:pr10-zero-parse",
        "30023:772e4f7ffd63a09748eb231e40e4dbd772fe997b8748c194f6204cfd8e4c933f:e2e-salad",
        "30023:772e4f7ffd63a09748eb231e40e4dbd772fe997b8748c194f6204cfd8e4c933f:e2e-toast",
        "30023:772e4f7ffd63a09748eb231e40e4dbd772fe997b8748c194f6204cfd8e4c933f:e2e-curry",
        "30023:783f7c04246e161314bd33853b20aecd3b027e3ef9c9783ec3d973365a2f269c:e2e-salad",
        "30023:bcaa6d25a3cac844c4631e082f62917fb6c8e3b80a3a05c87a65444310f04921:e2e-salad",
        "30023:434b9310a45d05d97c1d45354fb4a9857bf181db3194e107402c6cb002164c9a:e2e-salad",
        "30023:434b9310a45d05d97c1d45354fb4a9857bf181db3194e107402c6cb002164c9a:e2e-curry",
        "30023:f74290982a8cce6b8f869f3c33f5f9844bcbaf9ad22909904aae6f04efce69f4:e2e-curry",
        "30023:5a866ed1f65d68aec7c1879f810eff389ec15bfccf685b303df040d072f50864:e2e-curry",
        "30023:f62cdccd2c958cdd9726351cbc0e804ab9e32c47f6c62d649b0aaa23f9651f0d:e2e-salad",
        "30023:f62cdccd2c958cdd9726351cbc0e804ab9e32c47f6c62d649b0aaa23f9651f0d:e2e-curry",
        "30023:dd7e9c53ae4509aba878370c7285395e5d61b98e8eabdb33afa4deb6b6f68c13:e2e-salad",
        "30023:dd7e9c53ae4509aba878370c7285395e5d61b98e8eabdb33afa4deb6b6f68c13:e2e-curry",
    ]

    /// d-tag prefixes that hide regardless of pubkey. The 2.3 live-publish
    /// gate minted a new ephemeral key each run; eight pubkeys, one prefix.
    static let dTagPrefixes: [String] = [
        "ios-2.3-live-publish-",
    ]

    static func isHidden(coordinate: String) -> Bool {
        if coordinates.contains(coordinate) { return true }
        guard let dTag = dTag(fromCoordinate: coordinate) else { return false }
        return dTagPrefixes.contains { dTag.hasPrefix($0) }
    }

    static func isHidden(kind: Int, pubkey: String, dTag: String) -> Bool {
        isHidden(coordinate: "\(kind):\(pubkey):\(dTag)")
    }

    static func isHidden(_ event: NostrEvent) -> Bool {
        isHidden(kind: event.kind, pubkey: event.pubkey, dTag: RecipeParser.dTag(event))
    }

    /// `kind:pubkey:d-tag` — d-tag may itself contain colons, so only the
    /// first two separators are structural.
    private static func dTag(fromCoordinate coordinate: String) -> String? {
        guard let first = coordinate.firstIndex(of: ":") else { return nil }
        let afterKind = coordinate.index(after: first)
        guard let second = coordinate[afterKind...].firstIndex(of: ":") else { return nil }
        return String(coordinate[coordinate.index(after: second)...])
    }
}
