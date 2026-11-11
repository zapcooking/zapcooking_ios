# Stablecoin (USDB) Balance & Transactions — Follow-up Plan

Status: proposal, not started. Depends on the Breez SDK 0.28.1 bump (all three
apps) landing first. The web app is the behavioral reference; it already ships
most of this behind "USD mode".

## Goal

Let zap.cooking users hold part of their wallet in a dollar-stable token
(USDB), see it as a balance, transact through it, and watch conversions in
their activity — on web, iOS, and Android, with the same semantics.

## How stable balance works (Breez SDK)

- **Config (connect time)**: `stableBalanceConfig = StableBalanceConfig(tokens:
  [StableBalanceToken(label: "USDB", tokenIdentifier: USDB_ID)], defaultActiveLabel: …)`.
  Omit `defaultActiveLabel` to start deactivated (user opts in at runtime).
  USDB ID: `btkn1xgrvjwey5ngcagvap2dzzvsy4uk8ua9x69k82dwvt5e7ef9drm9qztux87`
  (same constant the web app ships as `USDB_TOKEN_IDENTIFIER`).
- **Runtime mode**: `updateUserSettings(stableBalanceActiveLabel: .set("USDB") | .unset)`;
  read state with `getUserSettings()`. Activating converts excess sats → USDB;
  deactivating converts the whole USDB balance back to sats.
- **Receive**: with the mode active, incoming sats auto-convert to USDB above
  a threshold (omit `thresholdSats` to use the protocol minimum).
- **Send**: when sats are insufficient the SDK converts USDB → sats
  automatically inside `prepareSendPayment` / `prepareLnurlPay`; responses
  carry a `conversionEstimate`, completed payments carry `conversionDetails`
  (status: pending/completed/failed/refund-needed/refunded).
- **Balances**: `getInfo()` returns `tokenBalances: [tokenIdentifier: TokenBalance]`
  (balance + tokenMetadata) alongside the sats balance.
- Omit `maxSlippageBps` unless we want tighter than the 10 bps default.

## Current state per app

| | Web (reference) | iOS | Android |
|---|---|---|---|
| stableBalanceConfig | set at connect (USDB, starts off) | not set | not set |
| USDB balance shown | yes (wallet panel, `$` prefix) | no | no |
| USD-mode toggle | yes (`updateUserSettings`) | no | no |
| Conversion notice on send | yes | no | no |
| USDB in activity list | yes (`asset.ticker` mapping) | no (`WalletTransaction` has no asset field) | no |

Web files to mirror: `src/lib/spark/index.ts` (config, `USDB_TOKEN_IDENTIFIER`,
balance mapping around line 262), `src/components/wallet/WalletPanel.svelte`
(toggle copy, `$` amounts, conversion disclosures).

## Phases

### Phase 1 — Enable + read-only balance (small, safe)
- iOS `SparkWallet.connect()` and Android `SparkRepository.connect()`:
  set `config.stableBalanceConfig` (USDB, **no** defaultActiveLabel — nothing
  changes for users until they opt in).
- Surface `getInfo().tokenBalances[USDB_ID]` next to the sats balance on the
  wallet screen (both apps). Cache alongside the existing balance cache.
- Screenshot evidence per repo policy (iOS: `docs/screenshots/wallet/`).

### Phase 2 — USD-mode toggle
- Settings row in wallet settings ("Hold funds in USD / USDB"), backed by
  `getUserSettings`/`updateUserSettings`. Copy follows web: activating
  converts eligible incoming bitcoin to USDB; turning it off converts the
  remaining USDB back. Disclose "conversion rates and fees apply" (web copy).
- Handle activation/deactivation as a surfaced async task (the conversion can
  take seconds; show progress, then refresh balances).

### Phase 3 — Transactions & conversion details
- Extend the transaction pipeline (`WalletTransaction` on iOS, the mapper in
  `SparkRepository`/`WalletViewModel` on Android) with an asset/ticker field
  fed from `PaymentDetails.token` cases, and render `$`-prefixed USDB rows
  like web.
- Show `conversionDetails` (both directions) in activity rows: converted
  amount, fee, status; surface `refundNeeded`/`refunded` prominently since a
  failed conversion means user action may be required.

### Phase 4 — Send flows
- No work needed for the common path (SDK auto-converts when sats are short),
  but verify `prepareSendPayment`/`prepareLnurlPay` responses surface
  `conversionEstimate` in the confirm sheet: "This payment may convert USDB
  to Bitcoin…" (web copy) before the user confirms.
- "Send entire balance": pass the full token balance with
  `FeePolicy.feesIncluded` + `ConversionOptions(.toBitcoin)` per SDK docs.

### Phase 5 — Later, optional (needs product sign-off)
- Receive USDT/USDC addresses (SDK ≥ 0.26), Cash App USDC/USDT off-ramp
  (0.27.2), partner fees on token payments. Each is a separate feature with
  its own compliance/copy review.

## Risks & notes

- **Fees/slippage**: every activation and every auto-conversion costs a
  conversion fee (default slippage cap 10 bps). Copy must set expectations on
  both the toggle and the send-confirm sheet, as web does.
- **Deactivation converts everything back** — a user with a large USDB
  balance will see one big conversion transaction; the activity feed needs to
  render it cleanly (Phase 3 prerequisite for Phase 2 launch).
- **Cross-device**: user settings are cached server-side by the SDK and sync
  across devices, so the toggle state should be read from `getUserSettings`
  on connect, not stored locally.
- **Number formatting**: USDB amounts are token units (U128) not msats —
  never reuse the msats formatting path for them; 2-decimal `$` formatting
  like web.
- App Store: no new entitlements; keep the "not financial advice / rates and
  fees apply" disclosures from web in the mobile copy.
