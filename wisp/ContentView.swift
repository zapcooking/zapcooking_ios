import SwiftUI

enum AppScreen {
    case splash
    case loading
    case onboarding
    /// Carries the terms acceptance given on the splash, so the wizard
    /// can't be reached without one.
    case signUp(TermsAcceptance)
    case main
}

struct ContentView: View {
    @State private var currentScreen: AppScreen = .splash
    /// The splash's two sign-in flows, each presented on the agreement its
    /// button gave (`PendingAgreement`) — never on a Bool beside a separate
    /// optional, which renders the flow empty on first presentation.
    @State private var nostrSignIn: PendingAgreement?
    @State private var appleSignIn: PendingAgreement?
    @State private var keypair: Keypair?
    @State private var checkedSavedAccount = false
    @State private var accountSwitchInProgress = false
    @State private var showAddAccount = false
    /// When the user creates a brand-new account via the Apple cloud flow,
    /// the keypair is generated and backed up before the wizard runs. We
    /// route them into `SignUpFlowView` with this pre-generated key so they
    /// still get the profile / follows / hashtags steps without minting a
    /// second key (which would leave the backed-up key abandoned).
    @State private var signUpExistingKeypair: Keypair?

    var body: some View {
        Group {
            switch currentScreen {
            case .splash:
                SplashView(
                    onContinueWithNostr: { nostrSignIn = PendingAgreement($0) },
                    onContinueWithApple: { appleSignIn = PendingAgreement($0) }
                )
                .sheet(item: $nostrSignIn) { pending in
                    NostrLoginSheet(
                        acceptance: pending.acceptance,
                        onLogin: { kp in
                            keypair = kp
                            nostrSignIn = nil
                            // An existing key: run the outbox builder unless this
                            // pubkey already has. Watch-only keys take the same
                            // route and get `OnboardingView`'s watch-only screen.
                            if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                                currentScreen = .loading
                            } else {
                                currentScreen = .onboarding
                            }
                        },
                        onCreateAccount: {
                            nostrSignIn = nil
                            currentScreen = .signUp(pending.acceptance)
                        }
                    )
                }
                .fullScreenCover(item: $appleSignIn) { pending in
                    AppleAuthView(
                        acceptance: pending.acceptance,
                        onCancel: { appleSignIn = nil },
                        onDone: { isNewAccount, kp in
                            keypair = kp
                            appleSignIn = nil
                            if isNewAccount {
                                // Brand-new account: run the same profile /
                                // follows / hashtags / intro-note wizard as
                                // a "Create new account" tap, passing the
                                // already-generated, already-backed-up key
                                // so the wizard doesn't mint a second one.
                                signUpExistingKeypair = kp
                                currentScreen = .signUp(pending.acceptance)
                            } else if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                                currentScreen = .loading
                            } else {
                                // Restored account: outbox-builder fetches
                                // kind-3 / kind-10002 from relays so the
                                // feed has follows + per-author write
                                // relays before MainView mounts.
                                currentScreen = .onboarding
                            }
                        }
                    )
                }

            case .signUp(let acceptance):
                SignUpFlowView(existingKeypair: signUpExistingKeypair, acceptance: acceptance) { kp in
                    keypair = kp
                    signUpExistingKeypair = nil
                    withAnimation { currentScreen = .main }
                }

            case .loading:
                LoadingView(delay: accountSwitchInProgress ? 350 : 800) {
                    accountSwitchInProgress = false
                    withAnimation { currentScreen = .main }
                }

            case .onboarding:
                if let keypair {
                    OnboardingView(keypair: keypair) {
                        withAnimation { currentScreen = .main }
                    }
                }

            case .main:
                if let keypair {
                    MainView(keypair: keypair, onLogout: {
                        ZapAnimationStore.shared.cancelAll()
                        self.keypair = nil
                        currentScreen = .splash
                    }, onSwitchAccount: { newKeypair in
                        ZapAnimationStore.shared.cancelAll()
                        self.keypair = newKeypair
                        accountSwitchInProgress = true
                        currentScreen = .loading
                    }, onAddAccount: {
                        showAddAccount = true
                    })
                }
            }
        }
        // Warm the splash food-photo cache on every launch (regardless of
        // screen) so the intro has cached photos the moment it shows. 24h TTL.
        .task { await FoodPhotoCache.shared.warmIfNeeded() }
        .fullScreenCover(isPresented: $showAddAccount) {
            LoginView { newKeypair in
                showAddAccount = false
                self.keypair = newKeypair
                // First time we see this pubkey on the device, run onboarding
                // so the outbox builder fetches kind-3 contacts and kind-10002
                // relay lists — without that the feed has no follows to query
                // and falls back to showing only the user's own posts. Already-
                // onboarded accounts (the user re-adding a previously-used
                // pubkey) skip straight to the loading splash.
                if NostrKey.isOnboardingComplete(pubkey: newKeypair.pubkey) {
                    accountSwitchInProgress = true
                    currentScreen = .loading
                } else {
                    currentScreen = .onboarding
                }
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            guard !checkedSavedAccount else { return }
            checkedSavedAccount = true
            if let saved = NostrKey.load() {
                keypair = saved
                // Ensure accounts set up before multi-account was added are
                // registered in wisp_accounts so they survive an "Add Account" flow.
                NostrKey.registerInAccountList(saved.pubkey)
                if NostrKey.isOnboardingComplete(pubkey: saved.pubkey) {
                    currentScreen = .loading
                } else {
                    currentScreen = .onboarding
                }
            }
        }
        .onChange(of: keypair?.pubkey) { _, newPubkey in
            if let pk = newPubkey {
                AppSettings.shared.loadQuickZapSettings(for: pk)
            }
        }
    }
}

#Preview {
    ContentView()
}
