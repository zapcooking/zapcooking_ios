import Foundation
import Testing
@testable import wisp

/// Guideline 1.2 EULA step. The agreement is given on an entry screen
/// before any key exists; `terms_accepted_<pubkey>` can only be written once
/// the key does. The property under test is that the gap between the two
/// never leaves a stored key without an acceptance record — not on a
/// finished sign-up, and not when the flow is abandoned right after the key
/// is stored.
///
/// The type system carries most of it: `NostrKey.save` and `saveWatchOnly`
/// take a non-optional `TermsAcceptance`, and every flow that stores a key
/// (splash → Apple / Nostr sheet / sign-up wizard, account switcher →
/// `LoginView` / sign-up wizard) is constructed with one. These tests pin
/// the runtime half: `save` records before it returns, and the earliest
/// point a flow can be abandoned already has the record.
@MainActor
@Suite(.serialized)
struct TermsAcceptanceTests {

    private func newKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private let acceptance = TermsAcceptance(
        version: TermsAcceptance.currentVersion,
        acceptedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    /// Run `body`, then remove every trace of the pubkeys it lists and put
    /// the test host's account list and active key back as they were.
    private func isolated(_ body: (inout [String]) -> Void) {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        var pubkeys: [String] = []
        defer {
            for pk in pubkeys { NostrKey.deleteAccount(pubkey: pk) }
            NostrKey.delete()
            UserDefaults.standard.set(priorAccounts, forKey: "wisp_accounts")
            if let priorActive { _ = NostrKey.switchAccount(pubkey: priorActive.pubkey) }
        }
        body(&pubkeys)
    }

    // MARK: - Record

    @Test func record_roundTripsVersionAndTimestamp() throws {
        let pk = try newKeypair().pubkey
        defer { UserDefaults.standard.removeObject(forKey: TermsAcceptance.defaultsKey(for: pk)) }

        #expect(TermsAcceptance.load(pubkey: pk) == nil)
        acceptance.record(for: pk)
        #expect(TermsAcceptance.defaultsKey(for: pk) == "terms_accepted_\(pk)")
        #expect(TermsAcceptance.load(pubkey: pk) == acceptance)
    }

    @Test func now_stampsCurrentVersion() {
        let before = Date()
        let a = TermsAcceptance.now()
        #expect(a.version == TermsAcceptance.currentVersion)
        #expect(a.acceptedAt >= before && a.acceptedAt <= Date())
    }

    // MARK: - No key without a record

    /// nsec log-in (splash sheet and account switcher) and Apple new /
    /// restore all store their key through this call.
    @Test func save_recordsAcceptanceWithTheKey() throws {
        let kp = try newKeypair()
        isolated { cleanup in
            cleanup.append(kp.pubkey)
            NostrKey.save(kp, acceptance: acceptance)

            #expect(NostrKey.loadAccount(pubkey: kp.pubkey) == kp)
            #expect(TermsAcceptance.load(pubkey: kp.pubkey) == acceptance)
        }
    }

    @Test func saveWatchOnly_recordsAcceptance() throws {
        let pk = try newKeypair().pubkey
        isolated { cleanup in
            cleanup.append(pk)
            NostrKey.saveWatchOnly(pubkey: pk, acceptance: acceptance)

            #expect(NostrKey.loadAccount(pubkey: pk) != nil)
            #expect(TermsAcceptance.load(pubkey: pk) == acceptance)
        }
    }

    /// "Create new account": the wizard stores its freshly minted key on
    /// mount (`SignUpFlowView.task` → `registerAccount()`), before the
    /// profile step. Abandoning right there — the app killed, the user never
    /// taps Continue — is the widest the gap can be. The key is in the
    /// Keychain and the account list, onboarding is not done (so the next
    /// launch resumes it as a saved account), and the record is there.
    @Test func signUpAbandonedAfterKeyStored_stillHasRecord() {
        isolated { cleanup in
            var pubkey = ""
            do {
                let vm = SignUpViewModel(acceptance: acceptance)
                pubkey = vm.keypair.pubkey
                cleanup.append(pubkey)
                #expect(NostrKey.loadAccount(pubkey: pubkey) == nil)
                #expect(TermsAcceptance.load(pubkey: pubkey) == nil)

                vm.registerAccount()
            } // wizard torn down: no step finished, `markComplete` never ran

            #expect(NostrKey.loadAccount(pubkey: pubkey) != nil)
            #expect(NostrKey.accounts().contains(pubkey))
            #expect(!NostrKey.isOnboardingComplete(pubkey: pubkey))
            #expect(TermsAcceptance.load(pubkey: pubkey) == acceptance)
        }
    }

    /// Nothing is stored before the key is: constructing the wizard (which
    /// SwiftUI may do several times and discard) writes no key and no record.
    @Test func signUpNeverMounted_leavesNothing() {
        let vm = SignUpViewModel(acceptance: acceptance)
        #expect(NostrKey.loadAccount(pubkey: vm.keypair.pubkey) == nil)
        #expect(TermsAcceptance.load(pubkey: vm.keypair.pubkey) == nil)
    }

    /// Continue with Apple, new account: the key is stored (with the
    /// acceptance) at PIN confirm, then handed to the wizard, which stores
    /// it again on mount. The record survives abandoning the wizard.
    @Test func appleNewAccountHandedToWizard_keepsRecord() throws {
        let kp = try newKeypair()
        isolated { cleanup in
            cleanup.append(kp.pubkey)
            NostrKey.save(kp, acceptance: acceptance)   // AppleAuthViewModel.createAndStoreNewAccount
            do {
                let vm = SignUpViewModel(existingKeypair: kp, acceptance: acceptance)
                vm.registerAccount()
            }

            #expect(NostrKey.loadAccount(pubkey: kp.pubkey) == kp)
            #expect(TermsAcceptance.load(pubkey: kp.pubkey) == acceptance)
        }
    }

    /// Re-adding an account from the switcher records the new agreement.
    @Test func loggingInAgain_recordsTheLatestAgreement() throws {
        let kp = try newKeypair()
        isolated { cleanup in
            cleanup.append(kp.pubkey)
            let older = TermsAcceptance(version: "2025-01-01", acceptedAt: Date(timeIntervalSince1970: 1_700_000_000))
            NostrKey.save(kp, acceptance: older)
            NostrKey.save(kp, acceptance: acceptance)
            #expect(TermsAcceptance.load(pubkey: kp.pubkey) == acceptance)
        }
    }

    // MARK: - Clean-up

    @Test func deleteAccount_removesRecord() throws {
        let kp = try newKeypair()
        isolated { cleanup in
            cleanup.append(kp.pubkey)
            NostrKey.save(kp, acceptance: acceptance)
            NostrKey.deleteAccount(pubkey: kp.pubkey)

            #expect(NostrKey.loadAccount(pubkey: kp.pubkey) == nil)
            #expect(TermsAcceptance.load(pubkey: kp.pubkey) == nil)
        }
    }
}
