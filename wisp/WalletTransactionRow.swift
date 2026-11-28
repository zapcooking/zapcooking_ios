import SwiftUI

/// A single row in a wallet transaction list. Used by both the dashboard
/// recent-strip and the full TransactionHistoryView.
struct WalletTransactionRow: View {
    let tx: WalletTransaction
    /// Wallet-screen balance display mode. `.fiat` renders amounts in the
    /// user's fiat currency; `.hidden` masks every number in the row.
    let displayMode: WalletBalanceDisplayMode
    /// When true (the full history list), the row taps to expand a detail
    /// drawer. The dashboard recent preview leaves this off so its rows stay
    /// compact and non-interactive.
    var expandable: Bool = false

    @State private var expanded = false

    var body: some View {
        let isIncoming = tx.type == .incoming
        // Counterparty resolution: prefer whatever the wallet backend
        // surfaced (none currently set this), then fall back to the
        // direction-appropriate paymentHash → pubkey map. Outgoing zaps
        // are recorded by ZapSender at zap time; incoming zaps are
        // recorded by NotificationsViewModel as kind-9735 receipts arrive
        // for the active user.
        let counterpartyPubkey = tx.counterpartyPubkey
            ?? (isIncoming
                ? ZapSender.sender(forPaymentHash: tx.paymentHash)
                : ZapSender.recipient(forPaymentHash: tx.paymentHash))
        let profile = counterpartyPubkey.flatMap { ProfileRepository.shared.get($0) }
        // Green means money arrived and red means it left. A conversion that
        // merely reshaped the balance (USD-mode toggles, stable-balance
        // receives) is neither — it renders neutral and signless. But a
        // conversion that funded a send DID move money out: the USDB left and
        // the payee got sats, so it renders as an outgoing payment. Each row
        // still shows what the conversion produced, in the destination's
        // denomination.
        let isConversion = tx.isConversion
        let isSendConversion = isConversion && tx.type == .outgoing
        let amountColor: Color = isSendConversion
            ? .red.opacity(0.85)
            : (isConversion
                ? .primary
                : (isIncoming ? Color.wispRepostColor : .red.opacity(0.85)))
        let sign = isSendConversion ? "-" : (isConversion ? "" : (isIncoming ? "+" : "-"))
        let sats = abs(tx.amountMsats) / 1000
        let feeSats = tx.feeMsats / 1000
        let hidden = displayMode == .hidden
        // `walletFiat` returns nil until the rate cache has loaded, so the
        // two-Text sats layout stays intact while the rate is in flight.
        // A token row has no sats value, so there is nothing to convert —
        // the fiat rate is sats-to-currency.
        let fiatAmount: String? = (displayMode == .fiat && !tx.isTokenTransfer)
            ? CurrencyFormatter.walletFiat(sats: sats)
            : nil
        let fiatFee: String? = (displayMode == .fiat && !tx.isTokenTransfer && feeSats > 0)
            ? CurrencyFormatter.walletFiat(sats: feeSats)
            : nil
        let descriptionLabel: String? = (tx.description?.isEmpty == false) ? tx.description : nil
        let fallbackLabel: String = isSendConversion
            ? "Sent"
            : (tx.conversionFrom.map { "Converted from \($0)" } ?? (isIncoming ? "Received" : "Sent"))
        let rowLabel = profile?.displayString ?? descriptionLabel ?? fallbackLabel

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    if let profile {
                        CachedAvatarView(url: profile.picture, size: 40)
                    } else if isConversion && !isSendConversion {
                        // Swap glyph in the wallet accent, not a green
                        // down-arrow: nothing entered the wallet, it changed
                        // shape inside it. A send-funded conversion keeps the
                        // outgoing arrow — money left for a payee.
                        Circle()
                            .fill(Color.wispZapColor.opacity(0.18))
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.wispZapColor)
                    } else {
                        Circle()
                            .fill((isIncoming ? Color.wispRepostColor : Color.red).opacity(0.18))
                            .frame(width: 40, height: 40)
                        Image(systemName: isIncoming ? "arrow.down" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(amountColor)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowLabel)
                        .font(.subheadline.weight(profile != nil ? .semibold : .regular))
                        .lineLimit(1)
                    Text(relativeTime(from: Int(tx.settledAt ?? tx.createdAt)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if hidden {
                        Text("\(sign)•••")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(amountColor)
                    } else if let assetTicker = tx.assetTicker {
                        // In the asset's own denomination — no fiat rate is
                        // applied: the rate converts satoshis, so applying it
                        // to a token amount would only produce a second
                        // wrong number.
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(sign)\(tx.assetAmountCompact ?? "?")")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(amountColor)
                            Text(assetTicker)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if let fiatAmount {
                        Text("\(sign)\(fiatAmount)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(amountColor)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(sign)\(CurrencyFormatter.formatNumber(sats))")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(amountColor)
                            Text("sats")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !hidden, !isIncoming, let assetFee = tx.assetFee, let ticker = tx.assetTicker {
                        Text("Fee: \(assetFee) \(ticker)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !hidden, !isIncoming, feeSats > 0 {
                        if let fiatFee {
                            Text("Fee: \(fiatFee)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Fee: \(CurrencyFormatter.formatNumber(feeSats)) sats")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if expandable {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }

            if expandable, expanded {
                TransactionDetailPanel(tx: tx)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// Expanded detail drawer for a transaction in the full history list. Shows
/// status, type, amount, fee, date, note, and the payment hash / transaction
/// ID with a copy button. On-chain transactions also surface a
/// mempool.space link (see `WalletTransaction.isOnchain` — currently inert
/// until on-chain payments land).
private struct TransactionDetailPanel: View {
    let tx: WalletTransaction
    @State private var hashCopied = false

    private var idLabel: String { tx.isOnchain ? "Transaction ID" : "Payment hash" }

    private var fullDate: String {
        let secs = tx.settledAt ?? tx.createdAt
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(secs)))
    }

    /// Mirror of the Android note filter — drop blank values, the literal
    /// string "null", and JSON blobs (zap-request payloads start with `{`).
    private var note: String? {
        guard let d = tx.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !d.isEmpty, d != "null", !d.hasPrefix("{") else { return nil }
        return d
    }

    var body: some View {
        let sats = abs(tx.amountMsats) / 1000
        let feeSats = tx.feeMsats / 1000

        VStack(alignment: .leading, spacing: 10) {
            TxDetailRow(label: "Status", value: tx.settledAt != nil ? "Completed" : "Pending")
            let assetTicker = tx.assetTicker
            // The conversion label replaces the plain rail type: a leg of a
            // Bitcoin↔USDB swap is neither On-chain nor Lightning to the
            // person reading it — what matters is what was swapped.
            TxDetailRow(
                label: "Type",
                value: tx.conversionFrom.map { "Converted from \($0)" }
                    ?? (assetTicker != nil ? assetTicker! : (tx.isOnchain ? "On-chain" : "Lightning"))
            )
            if assetTicker != nil {
                // Full precision here — the row rounds to two places for
                // legibility, but the detail view is where every digit
                // belongs.
                TxDetailRow(label: "Amount", value: "\(tx.assetAmount ?? "?") \(assetTicker!)")
                if let assetFee = tx.assetFee {
                    TxDetailRow(label: "Fee", value: "\(assetFee) \(assetTicker!)")
                }
            } else {
                TxDetailRow(label: "Amount", value: "\(CurrencyFormatter.formatNumber(sats)) sats")
                if feeSats > 0 {
                    TxDetailRow(label: "Network fee", value: "\(CurrencyFormatter.formatNumber(feeSats)) sats")
                }
            }
            TxDetailRow(label: "Date", value: fullDate)
            if let note {
                TxDetailRow(label: "Note", value: note)
            }
            HStack(alignment: .top, spacing: 12) {
                Text(idLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(tx.paymentHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = tx.paymentHash
                    withAnimation(.easeInOut(duration: 0.15)) { hashCopied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.easeInOut(duration: 0.2)) { hashCopied = false }
                    }
                } label: {
                    Image(systemName: hashCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hashCopied ? Color.green : Color.wispZapColor)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }
            // mempool.space link — follow-up PR once Spark surfaces a real
            // Bitcoin txid (separate from the internal UUID in paymentHash).
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 4)
    }
}

private struct TxDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
