# Gate 183 — NIP-46 remote signing (bunker + nostrconnect)

## Remote-signer size limit (Lazarus restores and any large publish)

NIP-46 wraps every `sign_event` inside an encrypted kind-24133 request:
NIP-44 encryption expands the payload ~1.35x and the transport event adds
a few hundred bytes. Signer apps cap what they accept per request —
Primal refuses requests over ~64 KB, which puts the ceiling on the
plaintext event at roughly 48 KB.

Consequence: a kind-3 follow list restores cleanly up to ~650 follows
over a remote signer. Past that (an 867-follow restore serializes to
~64 KB and was refused by Primal in testing), signing fails and the
signer's refusal is easy to misread as a broken session.

What the app does about it:

- `LazarusPublisher.remoteSignerSafeEventBytes` (48,000) is the threshold.
  A restore attempt on a remote account that serializes larger fails
  before any signing round-trip with
  `.tooLargeForRemoteSigner(serializedBytes:)`, and the review screen
  says exactly why, with the size, before the user taps Restore.
- Genuine signing failures carry the signer's own error string through
  `LazarusRestoreFailure.signFailed(String?)` (e.g. an "event too large"
  refusal from the signer).
- The same ceiling applies to any user-signed kind-3 republish (follow /
  unfollow) over a remote signer; trimming an oversized list must happen
  inside the signer app itself, or from a device holding the local key.

Upstream note for the Lazarus spec (feat/lazarus-spec-0.6.2): recovery
over a NIP-46 remote signer is bounded by the signer's request size cap;
restore flows should treat ~48 KB of serialized event as the practical
per-publish limit and surface it before attempting.
