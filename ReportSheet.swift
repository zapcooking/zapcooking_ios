import SwiftUI

/// Category picker + optional reason for a NIP-56 report.
///
/// Port of Android `ReportCategoryDialog`: no default category (a pre-selected
/// one would sign a public assertion the reporter never made), public-notice
/// copy above the reason field, submit disabled until they choose.
struct ReportSheet: View {
    let target: ReportTarget
    let keypair: Keypair
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var category: Nip56.ReportCategory?
    @State private var reason: String = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Why are you reporting this?")
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurface)
                    ForEach(Nip56.ReportCategory.allCases, id: \.self) { item in
                        Button {
                            category = item
                        } label: {
                            HStack {
                                Text(item.label)
                                    .foregroundStyle(Color.wispOnSurface)
                                Spacer()
                                if category == item {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.wispPrimary)
                                }
                            }
                        }
                        .accessibilityIdentifier("report-category-\(item.rawValue)")
                    }
                }

                Section {
                    Text("Reports are public. Yours is signed by your account and names the person you're reporting, along with anything you write below.")
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                    TextField("Add details (optional)", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("report-reason")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") { Task { await submit() } }
                        .disabled(category == nil || isSubmitting)
                        .accessibilityIdentifier("report-submit")
                }
            }
        }
        .accessibilityIdentifier("report-sheet")
    }

    private func submit() async {
        guard let category, !isSubmitting else { return }
        isSubmitting = true
        let outcome = await ReportSender.submit(
            target: target,
            category: category,
            reason: reason,
            keypair: keypair
        )
        isSubmitting = false
        ReportPresenter.shared.target = nil
        dismiss()
        switch outcome {
        case .sent:
            SuccessToast.shared.show("Report sent.")
        case .failed:
            SuccessToast.shared.show(
                "Couldn't send that report. You can try again.",
                icon: "exclamationmark.triangle.fill",
                accent: .red
            )
        case .needsKey:
            SuccessToast.shared.show(
                "Reporting is signed with your key. Sign in with a key to report this.",
                icon: "exclamationmark.triangle.fill",
                accent: .red
            )
        }
        onFinished?()
    }
}
