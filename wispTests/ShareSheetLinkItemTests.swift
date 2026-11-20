import UIKit
import Testing
@testable import wisp

/// The share sheet's Copy must put the link on the clipboard as plain text:
/// handed a `URL` it writes a URL-only item, which text-only readers see as
/// an empty clipboard. Every other target still gets a `URL`.
struct ShareSheetLinkItemTests {
    private static let link = "https://zap.cooking/r/naddr1abc"

    @Test func copy_getsPlainText() {
        let source = LinkItemSource(link: Self.link)
        let vc = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        let item = source.activityViewController(vc, itemForActivityType: .copyToPasteboard)
        #expect(item as? String == Self.link)
    }

    @Test func otherTargets_getURL() {
        let source = LinkItemSource(link: Self.link)
        let vc = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        for type in [UIActivity.ActivityType.message, .mail, nil] {
            let item = source.activityViewController(vc, itemForActivityType: type)
            #expect(item as? URL == URL(string: Self.link))
        }
    }
}
