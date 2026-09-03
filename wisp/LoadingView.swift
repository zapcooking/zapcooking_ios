import SwiftUI

struct LoadingView: View {
    var onReady: () -> Void
    var delay: Int = 800

    @State private var rotation: Double = 0
    @State private var appeared = false
    @State private var profile: ProfileData?

    /// Matches the size of OnboardingView's success checkmark so the
    /// spinner → check transition feels in-place, and gives the avatar
    /// inside enough room to read.
    private let spinnerSize: CGFloat = 64
    private let avatarSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("ZcLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            ZStack {
                CachedAvatarView(url: profile?.picture, size: avatarSize)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.wispPrimary, lineWidth: 4)
                    .frame(width: spinnerSize, height: spinnerSize)
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: spinnerSize, height: spinnerSize)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.wispBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            if let pubkey = NostrKey.load()?.pubkey {
                profile = ProfileRepository.shared.get(pubkey)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(delay))
            onReady()
        }
    }
}
