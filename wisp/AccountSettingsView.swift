import SwiftUI

/// Drawer → Settings → Account. Its own screen, first under Settings, so
/// account deletion is easy to find (Guideline 5.1.1(v)) rather than a
/// section under the policy links in About.
struct AccountSettingsView: View {
    let account: Account

    struct Account {
        let keypair: Keypair
        let walletStore: WalletStore?
        /// After deletion: the account the app switched to, or nil when the
        /// device was wiped and the app should return to the splash.
        let onDeleted: (Keypair?) -> Void
    }

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCardSection(title: "Account") {
                    NavigationLink {
                        DeleteAccountView(
                            keypair: account.keypair,
                            walletStore: account.walletStore,
                            onDeleted: account.onDeleted
                        )
                    } label: {
                        HStack {
                            Text("Delete Account")
                                .font(.system(size: 15))
                                .foregroundStyle(.red)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account-delete-account")
                }

                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}
