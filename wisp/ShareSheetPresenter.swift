import UIKit

/// Imperative system share sheet.
///
/// `ShareLink` is unreliable inside the post overflow `.popover`: the row's
/// `simultaneousGesture` dismisses the popover on the same tap that the
/// `ShareLink` uses to present, tearing down the presenter before the share
/// sheet appears (so it looks like "share does nothing"). Presenting a
/// `UIActivityViewController` on the window's topmost view controller
/// decouples the sheet from the dismissing popover.
///
/// Mirrors `PhotoPickerService.topmostPresenter()` — the share sheet lives in
/// the same presentation chain as whatever sheet / fullScreenCover is up, and
/// is *not* anchored to a lazy feed row (so it sidesteps the lazy-row sheet
/// teardown that motivated `ComposePresenter`).
@MainActor
enum ShareSheetPresenter {
    /// Present the system share sheet for `url`. Call after dismissing any
    /// presenting popover — defer to the next runloop tick so the popover's
    /// dismissal has registered before we present on the VC beneath it.
    static func present(url: String) {
        guard let presenter = topmostPresenter() else { return }

        // Share as a `URL` when the string parses so iOS offers richer link
        // targets (Messages preview, Safari); fall back to text.
        let items: [Any] = [LinkItemSource(link: url)]
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // iPad requires a popover anchor or this crashes. We're decoupled from
        // the originating ellipsis button, so anchor centered on the presenter.
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        presenter.present(activityVC, animated: true)
    }

    /// Walk the key window's VC chain to the topmost presented controller,
    /// skipping any controller mid-dismissal (e.g. the popover we just closed).
    private static func topmostPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
              ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
              let window = scene.windows.first(where: \.isKeyWindow)
              ?? scene.windows.first
        else { return nil }

        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}

/// The link as a `URL` for every target except Copy, which gets plain text.
///
/// The sheet's Copy action stores whatever item type it is handed. Handed a
/// `URL` it writes a `public.url` pasteboard item with no string flavor, so
/// text-only readers (a text field that rejects URL items, the Simulator's
/// Mac pasteboard sync, `simctl pbpaste`) see an empty clipboard — "Copy did
/// nothing". Handing Copy the string puts the link on the clipboard as text.
final class LinkItemSource: NSObject, UIActivityItemSource {
    let link: String

    init(link: String) { self.link = link }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        URL(string: link) ?? link
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        if activityType == .copyToPasteboard { return link }
        return URL(string: link) ?? link
    }
}
