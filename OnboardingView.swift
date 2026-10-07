import SwiftUI

struct OnboardingView: View {
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var viewModel: OnboardingViewModel

    init(keypair: Keypair, onComplete: @escaping () -> Void) {
        self.keypair = keypair
        self.onComplete = onComplete
        _viewModel = State(initialValue: OnboardingViewModel(keypair: keypair))
    }

    var body: some View {
        // Only an existing key reaches this screen — new accounts go through
        // `SignUpFlowView`, which marks onboarding done itself. A restored
        // account needs no teaching, so it goes straight to the wait for the
        // outbox builder: the follows feed has no relay scoreboard to query
        // until it finishes.
        Group {
            if keypair.isWatchOnly {
                WatchOnlyStep(viewModel: viewModel, keypair: keypair, onComplete: onComplete)
            } else {
                WaitingStep(viewModel: viewModel, keypair: keypair, onComplete: onComplete)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        // Force the step content to fill the screen so the background covers
        // every edge — the waiting step's VStack would otherwise size to its
        // widest text and let the system black show through on the sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .ignoresSafeArea()
        .task { await viewModel.startOutboxBuilding() }
    }
}

// MARK: - Waiting / Loading

private struct WaitingStep: View {
    var viewModel: OnboardingViewModel
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var messageIndex = 0
    @State private var rotation: Double = 0
    @State private var profile: ProfileData?
    /// Staged entrance flags. The ring draws itself in first; the avatar
    /// fades in once the ring has settled. Without the stage, the avatar
    /// painted alongside the slide-in transition before the ring was
    /// visually "in place," so for a frame it looked like a bare profile
    /// picture floating without its loading affordance.
    @State private var ringDrawn: CGFloat = 0
    @State private var avatarRevealed = false

    /// Spinner ring sized to match the success checkmark so the
    /// transition reads as the same widget swapping its content,
    /// and the avatar inside has room to read at a glance.
    private let spinnerSize: CGFloat = 64
    private let avatarSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: spinnerSize, height: spinnerSize)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                ZStack {
                    CachedAvatarView(url: profile?.picture, size: avatarSize)
                        .opacity(avatarRevealed ? 1 : 0)
                    Circle()
                        .trim(from: 0, to: ringDrawn)
                        .stroke(Color.wispPrimary, lineWidth: 4)
                        .frame(width: spinnerSize, height: spinnerSize)
                        .rotationEffect(.degrees(rotation))
                }
                .frame(width: spinnerSize, height: spinnerSize)
            }

            if viewModel.isReady {
                VStack(spacing: 8) {
                    Text("You\u{2019}re all set!")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    if viewModel.followCount > 0 {
                        let relayCount = viewModel.scoreBoard?.scoredRelays.count ?? 0
                        Text("Following \(viewModel.followCount) people across \(relayCount) relays")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            } else {
                Text(OnboardingViewModel.statusMessages[messageIndex])
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .id(messageIndex)
            }

            Spacer()

            if viewModel.isReady {
                Button("Let\u{2019}s go", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .tint(.wispPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer().frame(height: 48)
        }
        .animation(.easeInOut, value: viewModel.isReady)
        .onAppear {
            profile = ProfileRepository.shared.get(keypair.pubkey)
            // Stage 1: ring draws itself in. Stage 2: rotation kicks off
            // and the avatar fades in inside the now-visible ring.
            withAnimation(.easeOut(duration: 0.45)) { ringDrawn = 0.7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeIn(duration: 0.25)) { avatarRevealed = true }
            }
            Task {
                while !viewModel.isReady {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !viewModel.isReady else { break }
                    withAnimation {
                        messageIndex = (messageIndex + 1) % OnboardingViewModel.statusMessages.count
                    }
                }
            }
        }
    }
}

// MARK: - Watch-Only Step

private struct WatchOnlyStep: View {
    var viewModel: OnboardingViewModel
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var rotation: Double = 0
    @State private var ringDrawn: CGFloat = 0
    @State private var avatarRevealed = false
    @State private var profile: ProfileData?

    private let spinnerSize: CGFloat = 64
    private let avatarSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: spinnerSize, height: spinnerSize)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                ZStack {
                    CachedAvatarView(url: profile?.picture, size: avatarSize)
                        .opacity(avatarRevealed ? 1 : 0)
                    Circle()
                        .trim(from: 0, to: ringDrawn)
                        .stroke(Color.wispPrimary, lineWidth: 4)
                        .frame(width: spinnerSize, height: spinnerSize)
                        .rotationEffect(.degrees(rotation))
                }
                .frame(width: spinnerSize, height: spinnerSize)
            }

            VStack(spacing: 8) {
                Text("Watch-only mode")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("You can read but not post — no private key is stored on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            if viewModel.isReady {
                Button("Let\u{2019}s go", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .tint(.wispPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer().frame(height: 48)
        }
        .animation(.easeInOut, value: viewModel.isReady)
        .onAppear {
            profile = ProfileRepository.shared.get(keypair.pubkey)
            withAnimation(.easeOut(duration: 0.45)) { ringDrawn = 0.7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeIn(duration: 0.25)) { avatarRevealed = true }
            }
        }
    }
}

#Preview {
    OnboardingView(
        keypair: Keypair(privkey: "test", pubkey: "test"),
        onComplete: {}
    )
}
