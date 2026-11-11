import Foundation
import Testing
@testable import wisp

/// Fresh is free tier only (build spec §2 "Fresh feed relay"; Guideline
/// 2.1(b)): no membership copy, pitch, floor card or link-out, and no
/// login prompt. This scans every string literal in the Fresh sources (and
/// the Fresh section of `MainView`) for the words such copy would need.
@Suite struct FreshCopyTests {
    nonisolated static let forbidden = [
        "member", "cook+", "log in", "login", "sign in", "subscribe", "subscription",
        "upgrade", "unlock", "premium", "paid", "pricing", "older posts", "membership",
    ]

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// String literals on non-comment lines.
    static func literals(in source: String) -> [String] {
        var out: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let code = line.components(separatedBy: " //").first ?? line
            var inString = false
            var current = ""
            var escaped = false
            for ch in code {
                if inString {
                    if escaped { current.append(ch); escaped = false; continue }
                    if ch == "\\" { escaped = true; continue }
                    if ch == "\"" { out.append(current); current = ""; inString = false; continue }
                    current.append(ch)
                } else if ch == "\"" {
                    inString = true
                }
            }
        }
        return out
    }

    static func freshSources() throws -> [(String, String)] {
        let wisp = root.appendingPathComponent("wisp")
        var files: [(String, String)] = []
        for url in try FileManager.default.contentsOfDirectory(at: wisp, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("Fresh") && url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        let main = try String(contentsOf: root.appendingPathComponent("MainView.swift"), encoding: .utf8)
        if let start = main.range(of: "// MARK: - Fresh (behind"),
           let end = main.range(of: "private var feedBody: some View", range: start.upperBound..<main.endIndex) {
            files.append(("MainView.swift (Fresh section)", String(main[start.lowerBound..<end.lowerBound])))
        }
        return files
    }

    @Test("the scan finds the Fresh sources and their visible copy")
    func scanCoversFresh() throws {
        let files = try Self.freshSources()
        let names = Set(files.map(\.0))
        #expect(names.isSuperset(of: ["FreshFeedViewModel.swift", "FreshRelayClient.swift",
                                      "FreshFeedComponents.swift", "MainView.swift (Fresh section)"]))
        let all = files.flatMap { Self.literals(in: $0.1) }
        #expect(all.contains(FreshCaughtUpCard.title))
        #expect(all.contains("Couldn't reach Fresh"))
    }

    @Test("no Fresh string mentions membership, logging in, paying or older posts")
    func noMembershipCopy() throws {
        for (name, source) in try Self.freshSources() {
            for literal in Self.literals(in: source) {
                let lower = literal.lowercased()
                for word in Self.forbidden where lower.contains(word) {
                    Issue.record("\(name): \"\(literal)\" contains \"\(word)\"")
                }
            }
        }
    }

    @Test("the visible Fresh copy itself is clean")
    func componentCopy() {
        let visible = [FreshCaughtUpCard.title, FreshCaughtUpCard.subtitle,
                       FreshNewSinceDivider.label(1), FreshNewSinceDivider.label(7),
                       FeedKind.fresh.displayName]
        for text in visible {
            #expect(!Self.forbidden.contains { text.lowercased().contains($0) }, "\(text)")
        }
    }
}
