import Foundation

/// Common abstraction over a Lightning wallet backend.
///
/// Implementations:
/// - `NwcWallet` — talks to a remote wallet service over NIP-47.
/// - `SparkWallet` — embedded self-custodial wallet via the Breez Spark SDK.
///
/// All amounts are millisats unless otherwise noted.
@MainActor
protocol Wallet: AnyObject {
    var balanceMsats: Int64? { get }
    var isConnected: Bool { get }
    var statusLog: AsyncStream<String> { get }
    var paymentReceived: AsyncStream<Int64> { get }
    /// Emits whenever the wallet's balance changes internally (e.g. from a Spark `.synced` event
    /// or an NWC notification). Lets `WalletStore` keep its `@Observable` balance in sync without
    /// having to poll.
    var balanceUpdates: AsyncStream<Int64> { get }

    func hasConnection() -> Bool
    func connect() async
    func disconnect()
    func fetchBalance() async -> Result<Int64, WalletError>
    func payInvoice(_ bolt11: String) async -> Result<String, WalletError>
    func makeInvoice(amountMsats: Int64, description: String, expirySecs: Int64) async -> Result<String, WalletError>
    func listTransactions(limit: Int, offset: Int) async -> Result<[WalletTransaction], WalletError>
}

struct WalletTransaction: Identifiable, Codable {
    /// Composite of paymentHash + direction. A self-payment produces an
    /// (incoming, outgoing) pair that share a paymentHash; SwiftUI's
    /// `ForEach` collapses duplicate ids, so without the type suffix both
    /// rows render as whichever direction `ForEach` picked.
    var id: String { "\(paymentHash)|\(type.rawValue)" }
    let type: TransactionType
    let description: String?
    let paymentHash: String
    let amountMsats: Int64
    let feeMsats: Int64
    let createdAt: Int64
    let settledAt: Int64?
    let counterpartyPubkey: String?
    /// True when the payment has not yet settled (on-chain confirmations pending or
    /// Lightning HTLC in flight). Derived from the SDK's `PaymentStatus.pending`.
    var pending: Bool = false
    /// Real Bitcoin txid for on-chain deposits/withdrawals. Set from
    /// `PaymentDetails.deposit(txId:)` / `.withdraw(txId:)` in listTransactions.
    var bitcoinTxId: String?
    /// Ticker of the asset this row moved when it wasn't bitcoin — e.g.
    /// "USDB". Nil for every sats payment, which is the overwhelming
    /// majority.
    ///
    /// Spark wallets hold tokens alongside sats, and `Payment.amount` is
    /// documented as "satoshis **or token base units**". When this is set the
    /// row is rendered in the asset's own denomination and no fiat rate is
    /// applied — the rate converts satoshis, so applying it to a token amount
    /// would only produce a second wrong number. [amountMsats] stays strictly
    /// satoshi-denominated either way: it holds the bitcoin leg of a
    /// conversion, and zero for a pure token transfer, which has no bitcoin
    /// leg. [feeMsats] is zero on any asset row.
    var assetTicker: String? = nil
    /// Amount already scaled by the asset's decimals, at full precision.
    /// Kept as a string because token base units are `U128` and can exceed
    /// `Int64`. Detail views show this; rows show [assetAmountCompact].
    var assetAmount: String? = nil
    /// Fee in the same asset, scaled the same way. Nil when the fee is zero
    /// or is not denominated in this asset.
    var assetFee: String? = nil
    /// Asset a conversion started from — "Bitcoin" or "USDB" — when this row
    /// is one leg of a Bitcoin↔USDB swap rather than money entering or
    /// leaving the wallet.
    ///
    /// Drives the "Converted from Bitcoin" label in place of Received/Sent,
    /// and suppresses the +/- sign: a conversion is neither a credit nor a
    /// debit, and both of its legs land in the history.
    var conversionFrom: String? = nil

    /// True when this row moved something other than bitcoin.
    var isTokenTransfer: Bool { assetTicker != nil }

    /// True when this row is one leg of a Bitcoin↔USDB conversion.
    var isConversion: Bool { conversionFrom != nil }

    /// Row-sized amount: two decimal places, full precision kept in
    /// [assetAmount]. Dust that would round away to "0.00" keeps its full
    /// precision instead.
    var assetAmountCompact: String? {
        assetAmount.map { StableBalanceState.compactTokenAmount($0) }
    }

    /// Spark surfaces on-chain transactions with a UUID-formatted ID (contains hyphens)
    /// while Lightning payment hashes are always 64-char hex. Also true when a
    /// real Bitcoin txid was extracted from the payment details.
    var isOnchain: Bool {
        if bitcoinTxId != nil { return true }
        return paymentHash.contains("-")
    }

    enum TransactionType: String, Codable {
        case incoming
        case outgoing
    }
}

/// The wallet's USD (USDB) stablecoin balance and whether USD mode is on.
/// Spark-only: NWC wallets have no equivalent.
///
/// Deliberately separate from the sats balance — `GetInfoResponse.balanceSats`
/// is sats-only and tokens live in their own `tokenBalances` map, so the two
/// are genuinely distinct piles of money and are never summed. `amount` is
/// scaled to whole units at full precision as a decimal string, because token
/// base units are `U128` and can exceed `Int64`.
struct StableBalanceState: Codable, Equatable {
    var active: Bool
    var ticker: String
    /// Raw token base units as a decimal string; nil before the token metadata
    /// has arrived (a wallet with zero USDB reports none at all).
    var baseUnits: String?
    var decimals: UInt32

    /// Scaled to whole units at full precision, e.g. "15.766673".
    var amount: String? {
        baseUnits.map { Self.scaleTokenAmount(baseUnits: $0, decimals: decimals) }
    }

    /// Row-sized form of [amount], e.g. "15.77". Dust that would round away
    /// to "0.00" keeps its full precision — a real balance must never read
    /// as nothing having arrived.
    var amountCompact: String? {
        amount.map { Self.compactTokenAmount($0) }
    }

    /// True when there is USDB in the wallet, regardless of [active].
    var hasBalance: Bool {
        guard let baseUnits else { return false }
        return baseUnits.contains(":") == false
            && baseUnits.allSatisfy(\.isNumber)
            && !baseUnits.allSatisfy({ $0 == "0" })
    }

    /// Shift a token's base-unit amount by its decimal places for display.
    ///
    /// Operates on the decimal string rather than a numeric type on purpose:
    /// base units are `U128` and can exceed `Int64`, and `Double` would start
    /// losing cents well before that. Trailing zeros are dropped so a whole
    /// amount reads "150" rather than "150.000000".
    static func scaleTokenAmount(baseUnits: String, decimals: UInt32) -> String {
        let digits = baseUnits.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return baseUnits }
        guard decimals > 0 else { return digits }

        let places = Int(decimals)
        let padded = digits.count > places
            ? digits
            : String(repeating: "0", count: places - digits.count + 1) + digits
        let splitIndex = padded.index(padded.endIndex, offsetBy: -places)
        let whole = String(padded[padded.startIndex..<splitIndex])
        var fraction = String(padded[splitIndex...])

        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    /// Round a scaled token amount to two decimal places for display.
    ///
    /// Uses `Decimal`, not `Double`: these are money-shaped values and binary
    /// floating point starts misrepresenting cents well before the range a
    /// `U128` token can reach. Anything `Decimal` can't parse — or any amount
    /// that would round to zero without being zero — is passed through at full
    /// precision rather than displayed as a number it isn't.
    static func compactTokenAmount(_ scaled: String, places: Int = 2) -> String {
        guard scaled.contains("."), let value = Decimal(string: scaled) else { return scaled }
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, places, .plain)
        if rounded.isZero && !value.isZero { return scaled }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.usesGroupingSeparator = true
        return formatter.string(from: rounded as NSDecimalNumber) ?? scaled
    }
}

/// On-disk cache of last-known wallet state per pubkey. Lets the wallet tab
/// show real numbers instantly on cold launch instead of `?` while the network
/// catches up. Updated by `WalletStore` on every balance/transaction refresh.
enum WalletCache {
    private static func balanceKey(_ pubkey: String) -> String { "wallet_balance_msats_\(pubkey)" }
    private static func txsKey(_ pubkey: String) -> String { "wallet_transactions_\(pubkey)" }
    private static func stableKey(_ pubkey: String) -> String { "wallet_stable_balance_\(pubkey)" }

    static func loadBalance(for pubkey: String) -> Int64? {
        let v = UserDefaults.standard.object(forKey: balanceKey(pubkey)) as? NSNumber
        return v?.int64Value
    }

    static func saveBalance(_ msats: Int64, for pubkey: String) {
        UserDefaults.standard.set(NSNumber(value: msats), forKey: balanceKey(pubkey))
    }

    static func loadTransactions(for pubkey: String) -> [WalletTransaction] {
        guard let data = UserDefaults.standard.data(forKey: txsKey(pubkey)),
              let txs = try? JSONDecoder().decode([WalletTransaction].self, from: data) else { return [] }
        return txs
    }

    static func saveTransactions(_ txs: [WalletTransaction], for pubkey: String) {
        // Cap at 50 to keep UserDefaults footprint small.
        let trimmed = Array(txs.prefix(50))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: txsKey(pubkey))
        }
    }

    static func loadStableBalance(for pubkey: String) -> StableBalanceState? {
        guard let data = UserDefaults.standard.data(forKey: stableKey(pubkey)),
              let state = try? JSONDecoder().decode(StableBalanceState.self, from: data) else {
            return nil
        }
        return state
    }

    static func saveStableBalance(_ state: StableBalanceState, for pubkey: String) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stableKey(pubkey))
        }
    }

    static func clear(for pubkey: String) {
        UserDefaults.standard.removeObject(forKey: balanceKey(pubkey))
        UserDefaults.standard.removeObject(forKey: txsKey(pubkey))
        UserDefaults.standard.removeObject(forKey: stableKey(pubkey))
    }
}

enum WalletError: Error, LocalizedError {
    case notConnected
    case decodeFailed(String)
    case rpcError(code: String, message: String)
    case timeout
    case unsupportedEncryption
    case insufficientBalance
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Wallet not connected"
        case .decodeFailed(let m): "Decode failed: \(m)"
        case .rpcError(let code, let m): "\(code): \(m)"
        case .timeout: "Request timed out"
        case .unsupportedEncryption: "Wallet does not support requested encryption"
        case .insufficientBalance: "Insufficient balance"
        case .other(let m): m
        }
    }
}
