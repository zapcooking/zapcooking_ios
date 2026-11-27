import Foundation
import BreezSdkSpark

/// Reads the asset a Spark payment actually moved out of the shape the SDK
/// hands us. Port of the web client's `sparkPayment.ts` and Android's
/// `SparkPaymentAsset.kt`, kept deliberately parallel so the same wallet
/// renders the same history in every app.
///
/// The problem these functions exist to solve: Spark reports every amount
/// through one `Payment.amount` field, documented as "satoshis **or** token
/// base units", and a stable-balance receive keeps its original Lightning
/// method while its real amount is recorded only on the token side of the
/// conversion. Reading that field as sats turns a $15.77 USDB conversion
/// into "+15,866,330 sats".

/// A non-bitcoin asset moved by a Spark payment — in practice USDB.
///
/// When a payment carries one of these, the row is rendered in the asset's
/// own denomination and no fiat rate is applied: the rate converts satoshis,
/// so applying it here would only produce a second wrong number.
struct PaymentAsset: Equatable {
    /// e.g. "USDB".
    let ticker: String
    /// Unscaled base units as a decimal string; `U128`, so never an `Int64`.
    let baseUnits: String
    let decimals: UInt32
    /// Whether `Payment.fees` is denominated in this asset too.
    ///
    /// True for a genuine token transfer, where the SDK reports the fee in
    /// token base units. False when the asset came from conversion details:
    /// that payment settled over Lightning, so its fee is in sats while its
    /// amount is in token base units. There is no single denomination that
    /// describes both, so the fee is dropped rather than labelled with a
    /// currency it isn't in.
    let feeInAsset: Bool
}

/// One side of a Spark conversion, flattened to the fields we read.
///
/// Only the token side carries an [identifier][ConversionAssetSide.identifier]
/// — that is what tells the two legs of a conversion apart.
struct ConversionAssetSide: Equatable {
    let identifier: String?
    let ticker: String?
    let decimals: UInt32
    let baseUnits: String
}

/// A conversion, as the pair of sides we read off `ConversionDetails`.
struct SparkConversion: Equatable {
    let from: ConversionAssetSide
    let to: ConversionAssetSide
}

extension ConversionAssetSide {
    /// Flatten the SDK's `ConversionSide` down to the fields we read — the
    /// scaled-out amount as a decimal string, since `U128` never meets
    /// `Int64`.
    init(from side: ConversionSide) {
        self.init(
            identifier: side.asset.identifier,
            ticker: side.asset.ticker,
            decimals: side.asset.decimals,
            baseUnits: side.amount.description
        )
    }
}

/// Every side of every conversion on a payment, in order.
func conversionSides(_ conversions: [SparkConversion]) -> [ConversionAssetSide] {
    conversions.flatMap { [$0.from, $0.to] }
}

/// True when the conversion's destination is bitcoin — the payment ended as
/// sats, so the row is sats-denominated and the token side of the conversion
/// is what was *spent*, not what arrived.
///
/// Denominating both legs in the token — the web client's current rule —
/// makes a USD-mode round-trip read as two identical "1.20 USDB" rows with
/// the sats leg's outcome invisible.
func conversionDestinedForBitcoin(_ conversions: [SparkConversion]) -> Bool {
    guard !conversions.isEmpty else { return false }
    return conversions.allSatisfy { conversion in
        let ticker = conversion.to.ticker?.lowercased()
        return ticker == "btc" || ticker == "bitcoin"
    }
}

/// Work out which asset a payment moved, if not bitcoin. Returns nil for an
/// ordinary sats payment, which is the overwhelming majority.
///
/// Three sources, in order of trustworthiness:
///
///  1. `PaymentDetails.token` metadata — a direct token transfer. Ticker and
///     decimals come straight from the token's own definition, and the amount
///     is the payment's own.
///  2. The token side of the conversion details. Its amount is used, **not**
///     the payment's: on a stable-balance Lightning receive `Payment.amount`
///     is the sats that came in, while the USDB the user actually ended up
///     with is recorded only on this side.
///  3. `PaymentMethod.token` alone — the SDK notes the details can be empty.
///     Without metadata there are no decimals to scale by, so the base units
///     show under a neutral label rather than being passed off as sats.
///
/// Callers apply the to-side rule first: a conversion destined for bitcoin
/// yields a sats row, so this function is skipped for it entirely.
func extractPaymentAsset(
    amountBaseUnits: String,
    isTokenMethod: Bool,
    tokenTicker: String?,
    tokenDecimals: UInt32?,
    conversions: [SparkConversion]
) -> PaymentAsset? {
    if let tokenDecimals {
        return PaymentAsset(
            ticker: tokenTicker.nonBlank ?? "Token",
            baseUnits: amountBaseUnits,
            decimals: tokenDecimals,
            feeInAsset: true
        )
    }

    let tokenSide = conversionSides(conversions).first { $0.identifier.nonBlank != nil }
    if let tokenSide {
        return PaymentAsset(
            ticker: tokenSide.ticker.nonBlank ?? "Token",
            baseUnits: tokenSide.baseUnits,
            decimals: tokenSide.decimals,
            feeInAsset: false
        )
    }

    if isTokenMethod {
        return PaymentAsset(
            ticker: "tokens",
            baseUnits: amountBaseUnits,
            decimals: 0,
            feeInAsset: true
        )
    }

    return nil
}

/// The payment's satoshi value, which must stay strictly sats whatever else
/// the row displays.
///
/// With no asset, `Payment.amount` already is sats. With one, that field may
/// hold token base units, so the figure is taken from the bitcoin leg of the
/// conversion instead — and is zero for a pure token transfer, which has no
/// bitcoin leg and therefore no honest sats value at all.
func extractPaymentSats(
    amountBaseUnits: String,
    hasAsset: Bool,
    conversions: [SparkConversion]
) -> Int64 {
    if !hasAsset {
        return Int64(amountBaseUnits) ?? 0
    }
    let bitcoinSide = conversionSides(conversions).first {
        let ticker = $0.ticker?.lowercased()
        return ticker == "btc" || ticker == "bitcoin"
    }
    return Int64(bitcoinSide?.baseUnits ?? "") ?? 0
}

/// Name of the asset a conversion started from — "Bitcoin" or "USDB" — for
/// rows that read "Converted from Bitcoin" rather than "Received".
///
/// A conversion is neither a credit nor a debit: the same money stays in the
/// wallet in a different denomination. Labelling one "Received" invites the
/// reading that new funds arrived, and shows it twice over when both legs of
/// one swap land in the history.
///
/// Returns nil when the payment isn't a conversion.
func extractConversionFrom(_ conversions: [SparkConversion]) -> String? {
    let ticker = conversions.compactMap { $0.from.ticker.nonBlank }.first
    guard let ticker else { return nil }
    return ticker == "BTC" ? "Bitcoin" : ticker
}

private extension Optional where Wrapped == String {
    /// The blank-tolerant read used on conversion sides: whitespace-only
    /// tickers and identifiers carry no usable information.
    var nonBlank: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
