import SwiftUI

/// Surfaced when a relay sends a NIP-42 AUTH challenge for a relay that the user
/// hasn't pre-approved. Approving flips the relay's `auth` flag (adding it to
/// `generalRelays` if missing); the next connection auto-signs the challenge.
struct RelayAuthApprovalSheet: View {
    let relayUrl: String
    let keypair: Keypair
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.primary)
                Text("Relay requires AUTH")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.palette.onSurface)
            }

            Text(relayUrl)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .lineLimit(2)
                .truncationMode(.middle)

            Text("This relay asks Zap Cooking to prove your identity (NIP-42). Approving signs a one-time event with your key. You can revoke this any time in Relay settings.")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)

            HStack(spacing: 12) {
                Button(action: deny) {
                    Text("Deny")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(theme.palette.onSurface)
                        .background(theme.palette.surfaceVariant)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button(action: approve) {
                    Text("Approve")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(theme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }

    private func approve() {
        RelaySettingsRepository.shared.approveAuth(relayUrl, keypair: keypair)
        onDismiss()
    }

    private func deny() {
        onDismiss()
    }
}
