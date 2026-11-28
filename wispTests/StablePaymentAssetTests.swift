import Testing
@testable import wisp

/// The asset-extraction rules for Spark payments that moved something other
/// than bitcoin — in practice USDB. Fixtures mirror
/// `SparkPaymentAssetTest.kt` on Android and `sparkPayment.test.ts` on web so
/// a behavioral drift shows up as a red test in one repo only.
@Suite
struct StablePaymentAssetTests {

    // MARK: - Direct token transfers

    @Test func directTokenMetadataCarriesTheAssetsOwnDenomination() {
        let asset = extractPaymentAsset(
            amountBaseUnits: "1200000",
            isTokenMethod: false,
            tokenTicker: "USDB",
            tokenDecimals: 6,
            conversions: []
        )
        #expect(asset?.ticker == "USDB")
        #expect(asset?.baseUnits == "1200000")
        #expect(asset?.decimals == 6)
        // The SDK reports this payment's fee in token base units too.
        #expect(asset?.feeInAsset == true)
    }

    @Test func blankTickerFallsBackToToken() {
        let asset = extractPaymentAsset(
            amountBaseUnits: "7",
            isTokenMethod: false,
            tokenTicker: "  ",
            tokenDecimals: 4,
            conversions: []
        )
        #expect(asset?.ticker == "Token")
    }

    // MARK: - Conversion legs

    @Test func bitcoinToUsdbArrivalReadsTheTokenSide() {
        // A stable-balance Lightning receive keeps its Lightning method;
        // payment.amount holds the sats that came in while the USDB the user
        // actually ended up with is recorded only on the conversion's token
        // side. The row shows the USDB.
        let conversions = [usdbArrival]
        let asset = extractPaymentAsset(
            amountBaseUnits: "158663",
            isTokenMethod: false,
            tokenTicker: nil,
            tokenDecimals: nil,
            conversions: conversions
        )
        #expect(asset?.ticker == "USDB")
        #expect(asset?.baseUnits == "1200000")
        // The payment settled over Lightning, so its fee is in sats, not in
        // the asset — dropped rather than mislabelled.
        #expect(asset?.feeInAsset == false)
        #expect(extractConversionFrom(conversions) == "Bitcoin")
        // Not destined for bitcoin, so the row is an asset row that displays
        // the USDB. The sats value records the 1,950 that passed through the
        // bitcoin leg — kept inert in amountMsats, never displayed here.
        #expect(!conversionDestinedForBitcoin(conversions))
        #expect(extractPaymentSats(amountBaseUnits: "158663", hasAsset: true, conversions: conversions) == 1_950)
    }

    @Test func usdbToBitcoinLegIsSatsDenominated() {
        // Disabling USD mode converts the USDB balance back: the row is a
        // plain sats row whose amount comes off the conversion's bitcoin leg,
        // because payment.amount may hold the token units that left.
        let conversions = [usdbExit]
        #expect(conversionDestinedForBitcoin(conversions))
        let sats = extractPaymentSats(
            amountBaseUnits: "1200000",
            hasAsset: true,
            conversions: conversions
        )
        #expect(sats == 1_950)
        #expect(extractConversionFrom(conversions) == "USDB")
    }

    @Test func emptyConversionsAreNeverDestinedForBitcoin() {
        #expect(!conversionDestinedForBitcoin([]))
    }

    @Test func mixedSideConversionsDoNotTriggerTheSatsRule() {
        // A defensively-shaped fixture: if the SDK ever reports sides in a
        // mix, only a unanimous bitcoin destination flips the row to sats.
        let conversions = [
            SparkConversion(
                from: side(identifier: nil, ticker: "BTC", decimals: 8, baseUnits: "1000"),
                to: side(identifier: "usdb-token-id", ticker: "USDB", decimals: 6, baseUnits: "500000")
            ),
            SparkConversion(
                from: side(identifier: "usdb-token-id", ticker: "USDB", decimals: 6, baseUnits: "500000"),
                to: side(identifier: nil, ticker: "BTC", decimals: 8, baseUnits: "2000")
            )
        ]
        #expect(!conversionDestinedForBitcoin(conversions))
    }

    // MARK: - Method fallback

    @Test func tokenMethodWithoutMetadataShowsNeutralLabel() {
        // The SDK notes details can be empty. Without metadata there are no
        // decimals to scale by, so the base units show under a neutral label
        // rather than being passed off as sats.
        let asset = extractPaymentAsset(
            amountBaseUnits: "999",
            isTokenMethod: true,
            tokenTicker: nil,
            tokenDecimals: nil,
            conversions: []
        )
        #expect(asset?.ticker == "tokens")
        #expect(asset?.decimals == 0)
    }

    @Test func plainSatsPaymentsCarryNoAsset() {
        #expect(extractPaymentAsset(
            amountBaseUnits: "21000",
            isTokenMethod: false,
            tokenTicker: nil,
            tokenDecimals: nil,
            conversions: []
        ) == nil)
    }

    // MARK: - Display helpers (shared with StableBalanceState)

    @Test func scalingAndRoundingMatchTheOtherApps() {
        #expect(StableBalanceState.scaleTokenAmount(baseUnits: "15766673", decimals: 6) == "15.766673")
        #expect(StableBalanceState.scaleTokenAmount(baseUnits: "150000000", decimals: 6) == "150")
        #expect(StableBalanceState.compactTokenAmount("15.766673") == "15.77")
        // Dust that would round away to zero keeps its full precision — a
        // real balance must never display as nothing having arrived.
        #expect(StableBalanceState.compactTokenAmount("0.000001") == "0.000001")
    }

    // MARK: - Fixtures

    /// BTC 1,950 sats → USDB 1.20 (the "Converted from Bitcoin" leg).
    private var usdbArrival: SparkConversion {
        SparkConversion(
            from: side(identifier: nil, ticker: "BTC", decimals: 8, baseUnits: "1950"),
            to: side(identifier: "usdb-token-id", ticker: "USDB", decimals: 6, baseUnits: "1200000")
        )
    }

    /// USDB 1.20 → BTC 1,950 sats (the "Converted from USDB" leg).
    private var usdbExit: SparkConversion {
        SparkConversion(
            from: side(identifier: "usdb-token-id", ticker: "USDB", decimals: 6, baseUnits: "1200000"),
            to: side(identifier: nil, ticker: "BTC", decimals: 8, baseUnits: "1950")
        )
    }

    private func side(
        identifier: String?,
        ticker: String?,
        decimals: UInt32,
        baseUnits: String
    ) -> ConversionAssetSide {
        ConversionAssetSide(
            identifier: identifier,
            ticker: ticker,
            decimals: decimals,
            baseUnits: baseUnits
        )
    }
}
