import Foundation

#if DEBUG
/// Launch-argument harness, mirroring `-ComposerDragHarness`: launch with
/// `-ThreadHarnessSeed <event id>` (and optionally
/// `-ThreadHarnessAuthor <pubkey>`, the same `authorHint` a `ThreadRoute`
/// carries) to push the thread screen at launch. Exists so relay-driven
/// verification of `ThreadViewModel` on the simulator needs no UI driving.
enum ThreadHarness {
    static var seedEventId: String? { value(of: "-ThreadHarnessSeed") }
    static var authorHint: String? { value(of: "-ThreadHarnessAuthor") }

    private static func value(of flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// `-SearchHarness <query> [-SearchHarnessMode people|notes|recipes]`:
/// launch into the real search tab with the query pre-typed (and the mode
/// pre-selected before the debounced search fires), for screenshot UI
/// tests (same pattern as `-ThreadHarnessSeed`). Requires a logged-in
/// account — pair it with `-WatchOnlyLogin <pubkey>`. One mode per launch:
/// search relays rate-limit identical filters on one connection, so the
/// four mode screenshots each get a fresh app process.
enum SearchHarness {
    static var query: String? { value(of: "-SearchHarness") }

    static var mode: SearchViewModel.Mode? {
        guard let raw = value(of: "-SearchHarnessMode") else { return nil }
        return SearchViewModel.Mode(rawValue: raw)
    }

    private static func value(of flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
