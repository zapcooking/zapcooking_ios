import SwiftUI

private let tileSize: CGFloat = 76
private let tileGap: CGFloat = 6
private let tileRadius: CGFloat = 12
/// Dark ink background matching Android's splash `BG_COLOR` (#111827).
private let splashBG = Color(red: 0x11 / 255.0, green: 0x18 / 255.0, blue: 0x27 / 255.0)

struct SplashView: View {
    @State private var viewModel = SplashViewModel()
    /// The bottom action buttons fade in after the splash has had a moment
    /// to settle. Without the delay the layout visibly twitches while the
    /// home indicator's safe-area inset stabilises during the initial
    /// presentation, jumping the buttons before the background is in place.
    @State private var actionsVisible = false
    var onContinueWithNostr: () -> Void = {}
    var onContinueWithApple: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width + tileGap) / (tileSize + tileGap)))
            // Size tiles so `cols` of them + gaps exactly fill the screen width —
            // edge-to-edge, no centered side margins.
            let edgeTileSize = (geo.size.width - tileGap * CGFloat(max(0, cols - 1))) / CGFloat(cols)
            let rows = Int((geo.size.height + tileGap) / (edgeTileSize + tileGap)) + 1
            let photos = viewModel.foodPhotos

            ZStack {
                // Animated food-photo tile grid, pinned to the top and clipped
                // to the screen. Mirrors Android SplashScreen's AnimatedFoodTile
                // grid: rounded tiles with a staggered cross-fade.
                VStack(spacing: tileGap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: tileGap) {
                            ForEach(0..<cols, id: \.self) { col in
                                FoodPhotoTile(
                                    photos: photos,
                                    tileIndex: row * cols + col,
                                    numCols: cols,
                                    alpha: Self.tileAlpha(row: row, col: col),
                                    size: edgeTileSize
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()

                // Full-height gradient: food tiles peek through at the top,
                // the centered logo and sign-in buttons stay readable.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.30),
                        .init(color: splashBG.opacity(0.50), location: 0.50),
                        .init(color: splashBG.opacity(0.88), location: 0.72),
                        .init(color: splashBG, location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Centered logo + wordmark + tagline, sign-in buttons below.
                // Matches Android's splash composition (logo with radial glow,
                // wordmark, tagline, then buttons).
                VStack(spacing: 0) {
                    Spacer()

                    AnimatedLogo()

                    Image("ZcWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 32)
                        .padding(.top, 16)

                    Text("Food is Open Source")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 10)

                    Spacer()

                    VStack(spacing: 10) {
                        // Continue with Apple is the cloud key-recovery path
                        // (iCloud Keychain + PIN). Gated on
                        // `AppleAuthConfig.isConfigured` (SIWA entitlement
                        // present in this build). If iCloud isn't signed in,
                        // AppleAuthView surfaces a friendly error after tap.
                        if AppleAuthConfig.isConfigured {
                            ContinueWithAppleButton(action: onContinueWithApple)
                        }

                        ContinueWithNostrButton(action: onContinueWithNostr)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(splashBG)
        .ignoresSafeArea()
        .task {
            // Hold the content hidden until the screen has settled (the home
            // indicator's safe-area inset shifts during the first ~400ms of
            // presentation); every shift happens behind a 0-opacity curtain.
            try? await Task.sleep(for: .milliseconds(1800))
            withAnimation(.easeOut(duration: 0.35)) { actionsVisible = true }
        }
        // NOTE: the food-photo fetch is intentionally NOT cancelled on
        // disappear — it runs to completion so the 24h cache populates even
        // if the user logs in quickly. The view model is retained by the
        // fetch task until it finishes.
    }

    /// Per-tile wash alpha, matching Android's `TILE_ALPHAS` table — subtle so
    /// the grid reads as a textured backdrop, not a foreground collage.
    private static let tileAlphas: [Double] = [
        0.10, 0.06, 0.14, 0.08, 0.12, 0.05, 0.16, 0.07, 0.11, 0.09,
        0.13, 0.07, 0.09, 0.15, 0.06, 0.11, 0.08, 0.14, 0.10, 0.12,
    ]

    private static func tileAlpha(row: Int, col: Int) -> Double {
        tileAlphas[(row * 3 + col * 7) % tileAlphas.count]
    }
}

/// Apple HIG-compliant "Continue with Apple" button. We don't use SwiftUI's
/// built-in `SignInWithAppleButton` because it triggers its own
/// `ASAuthorizationController` internally — we want our `AppleSignInManager`
/// to own that so the async/await bridge lives in one place. The visual
/// styling (white background, black logo, black "Continue with Apple"
/// wording in a capsule, ≥ 44pt height) follows the HIG so this still
/// passes review.
private struct ContinueWithAppleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "applelogo")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.black)
                Text("Continue with Apple")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(Color.white, in: Capsule())
    }
}

/// Matches the Android "Continue with Nostr" pill from `SplashScreen.kt`
/// (lines 242–269): dark-purple background, light-purple text and purple
/// border, with the Nostr ostrich mark to the left.
private struct ContinueWithNostrButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NostrOstrichIcon()
                    .frame(width: 22, height: 22)
                Text("Continue with Nostr")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0xE9/255.0, green: 0xDD/255.0, blue: 0xFF/255.0))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(Color(red: 0x1A/255.0, green: 0x0E/255.0, blue: 0x2E/255.0),
                    in: Capsule())
        .overlay(
            Capsule().stroke(Color(red: 0x8E/255.0, green: 0x30/255.0, blue: 0xEB/255.0), lineWidth: 1)
        )
    }
}

private struct NostrOstrichIcon: View {
    private static let orange = Color(red: 0xFD/255.0, green: 0x96/255.0, blue: 0x2C/255.0)
    private static let purple = Color(red: 0xA2/255.0, green: 0x23/255.0, blue: 0xE9/255.0)

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 240
            let sy = size.height / 270

            var legs = Path()
            legs.addRect(CGRect(x: 105 * sx, y: 225 * sy, width: 30 * sx, height: 30 * sy))
            legs.addRect(CGRect(x: 165 * sx, y: 225 * sy, width: 30 * sx, height: 30 * sy))
            legs.addRect(CGRect(x: 195 * sx, y: 75 * sy, width: 30 * sx, height: 30 * sy))
            ctx.fill(legs, with: .color(Self.orange))

            let pts: [(CGFloat, CGFloat)] = [
                (165, 45), (165, 15), (135, 15), (135, 45), (135, 75), (135, 105),
                (105, 105), (75, 105), (45, 105), (15, 105), (15, 135), (45, 135),
                (45, 165), (75, 165), (75, 195), (105, 195), (105, 225), (135, 225),
                (135, 195), (165, 195), (165, 225), (195, 225), (195, 195), (195, 165),
                (195, 135), (195, 105), (195, 75), (195, 45)
            ]
            var body = Path()
            body.move(to: CGPoint(x: pts[0].0 * sx, y: pts[0].1 * sy))
            for i in 1..<pts.count {
                body.addLine(to: CGPoint(x: pts[i].0 * sx, y: pts[i].1 * sy))
            }
            body.closeSubpath()
            ctx.fill(body, with: .color(Self.purple))
        }
        .aspectRatio(240.0 / 270.0, contentMode: .fit)
    }
}

/// One rounded, cross-fading food-photo tile. Mirrors Android's
/// `AnimatedFoodTile`: a rounded square that holds one photo at a time and
/// fades to another on a staggered timer, so the grid gently shuffles instead
/// of feeling static.
private struct FoodPhotoTile: View {
    let photos: [String]
    let tileIndex: Int
    let numCols: Int
    let alpha: Double
    let size: CGFloat

    @State private var displayURL: String?

    var body: some View {
        RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
            .fill(Color.white.opacity(alpha))
            .frame(width: size, height: size)
            .overlay {
                if let displayURL, let url = URL(string: displayURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
                    .transition(.opacity)
                }
            }
            .clipped()
            // Restart cycling whenever the photo set changes (cache load → fetch).
            .task(id: photos) { await cycle() }
    }

    private func cycle() async {
        guard !photos.isEmpty else { displayURL = nil; return }
        // Spread starting photos so adjacent tiles don't share an image.
        let start = (tileIndex * 7 + (tileIndex / max(1, numCols)) * 13) % photos.count
        displayURL = photos[start]
        guard photos.count > 1 else { return }
        var idx = start
        // Stagger the first swap so tiles don't all flip at once.
        try? await Task.sleep(for: .milliseconds((tileIndex * 371) % 8000))
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2500 + (tileIndex * 197) % 3500))
            if Task.isCancelled { break }
            idx = (idx + 1) % photos.count
            withAnimation(.easeInOut(duration: 0.7)) { displayURL = photos[idx] }
        }
    }
}

private struct AnimatedLogo: View {
    @State private var bob = false
    @State private var sway = false

    var body: some View {
        Image("ZcLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 88, height: 88)
            .background(
                // Radial glow so the logo reads against the food collage,
                // matching Android's `drawBehind` radial gradient.
                RadialGradient(
                    colors: [.black.opacity(0.85), .black.opacity(0.55), .black.opacity(0.15), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 160
                )
                .frame(width: 300, height: 300)
            )
            .offset(y: bob ? -8 : 0)
            .rotationEffect(.degrees(sway ? 3 : -3))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    bob = true
                }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: true)) {
                    sway = true
                }
            }
    }
}

/// Bottom sheet mirroring Android's `NostrLoginSheet` (lines 322–474 of
/// `SplashScreen.kt`): ostrich + title + body, nsec/npub field with
/// show/hide + QR trailing icons, "Log In" primary button, divider,
/// "Create new account" outlined button.
struct NostrLoginSheet: View {
    var onLogin: (Keypair) -> Void
    var onCreateAccount: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    @State private var showQRScanner = false

    var body: some View {
        VStack(spacing: 0) {
            NostrOstrichIcon()
                .frame(width: 48, height: 48)
                .padding(.top, 24)

            Text("Continue with Nostr")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.wispOnSurface)
                .padding(.top, 12)

            Text("Your key never leaves the device.")
                .font(.subheadline)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Group {
                    if isSecure {
                        SecureField("nsec or npub…", text: $nsecInput)
                    } else {
                        TextField("nsec or npub…", text: $nsecInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: nsecInput) { _, _ in error = nil }

                Button {
                    isSecure.toggle()
                } label: {
                    Image(systemName: isSecure ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    showQRScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            NsecIdentityPreview(nsecInput: nsecInput)
                .padding(.top, 12)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 8)
            }

            Button(action: login) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Log In").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .clipShape(Capsule())
            .disabled(nsecInput.isEmpty || isLoading)
            .padding(.top, 12)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.wispOutline.opacity(0.5))
                    .frame(height: 1)
            }
            .padding(.vertical, 20)

            Button(action: onCreateAccount) {
                Text("Create new account")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.wispPrimary)
            .clipShape(Capsule())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.wispBackground)
        // Just a touch taller than `.medium`: the previous default left
        // the ostrich crowded against the top edge, and the identity
        // preview's 64pt reserved slot pushed the bottom controls under
        // the safe-area inset. This bump fits both without covering the
        // discovery grid above. `.large` is offered as a secondary
        // detent for users who want more room.
        .presentationDetents([.height(500), .large])
        .presentationBackground(Color.wispBackground)
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showQRScanner) {
            QRCodeScannerView(
                onScanned: { value in handleScanned(value) },
                onCancel: { showQRScanner = false }
            )
            .ignoresSafeArea()
        }
        .onAppear { nsecPasteAllowed = true }
        .onDisappear { nsecPasteAllowed = false }
    }

    private func login() {
        error = nil
        let trimmed = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keypair = NostrKey.parseNsec(trimmed) {
            isLoading = true
            NostrKey.save(keypair)
            onLogin(keypair)
            return
        }
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            isLoading = true
            NostrKey.saveWatchOnly(pubkey: pubkeyHex)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }
        error = "Couldn't read that key. Paste an nsec (\"nsec1…\"), an npub / nprofile to browse watch-only, or a 64-character hex private key."
    }

    private func handleScanned(_ value: String) {
        showQRScanner = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keypair = NostrKey.parseNsec(trimmed) {
            NostrKey.save(keypair)
            onLogin(keypair)
            return
        }
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            NostrKey.saveWatchOnly(pubkey: pubkeyHex)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }
        error = "Unrecognized format. Scan an nsec, npub, nprofile, or hex private key."
    }
}

// Legacy palette accessors. Prefer `@Environment(\.theme)` and `theme.palette.*` /
// `theme.primary` directly in new code — these globals reflect the active theme by
// reading `ResolvedThemeProxy.current` synchronously. They live on for the many
// existing call sites that haven't been migrated yet.
//
// `nonisolated` so SwiftUI views, `Sendable` closures, and non-MainActor code
// (`UIViewRepresentable` coordinators, `Task.detached` rendering helpers) can
// read these without needing an actor hop. The underlying `ResolvedThemeProxy`
// is lock-protected.
nonisolated extension Color {
    static var wispBackground: Color { ResolvedThemeProxy.current.palette.background }
    static var wispSurface: Color { ResolvedThemeProxy.current.palette.surface }
    static var wispSurfaceVariant: Color { ResolvedThemeProxy.current.palette.surfaceVariant }
    static var wispPrimary: Color { ResolvedThemeProxy.current.primary }
    /// Zap-tinted surfaces — post bolt icon, zap count text, top-zapper
    /// indicator, wallet zap accents, the Lightning QR icon, etc. Reads
    /// from `ResolvedTheme.zap`, which on the `custom` theme equals
    /// `primary` so a user-picked accent flows through; on every other
    /// preset it stays the curated palette value chosen for hue contrast.
    /// The celebratory in-flight bolt pulse uses `wispZapAnimationColor`
    /// instead — never use this accessor for that animation.
    static var wispZapColor: Color { ResolvedThemeProxy.current.zap }
    /// Vivid variant of `wispZapColor`, reserved for the in-flight bolt
    /// animation (`LightningPulseView`). Plain `wispZapColor` reads muddy
    /// in light mode because the primary is darkened for button contrast;
    /// the burst needs a brightness floor or the animation looks dim on
    /// the near-white surface. Static UI everywhere else stays on the
    /// plain `wispZapColor`.
    static var wispZapAnimationColor: Color { ResolvedThemeProxy.current.zapAnimation }
    static var wispRepostColor: Color { ResolvedThemeProxy.current.palette.repost }
    static var wispBookmarkColor: Color { ResolvedThemeProxy.current.bookmark }
    static var wispPaidColor: Color { ResolvedThemeProxy.current.palette.paid }
    static var wispOnSurface: Color { ResolvedThemeProxy.current.palette.onSurface }
    static var wispOnSurfaceVariant: Color { ResolvedThemeProxy.current.palette.onSurfaceVariant }
    static var wispOutline: Color { ResolvedThemeProxy.current.palette.outline }
}

/// Thread-safe holder for the active resolved theme.
///
/// Reads happen on every `View.body` re-evaluation, including inside
/// `Sendable` closures and `UIViewRepresentable.updateUIView`, so the
/// accessor must not require MainActor. Writes come from the root view's
/// `task` via `update(_:)` whenever `AppSettings` or the system color
/// scheme change. Brief staleness during an update (one frame) is fine —
/// theme transitions are visual, not load-bearing.
nonisolated enum ResolvedThemeProxy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: ResolvedTheme = .default

    static var current: ResolvedTheme {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    static func update(_ theme: ResolvedTheme) {
        lock.lock(); defer { lock.unlock() }
        _current = theme
    }
}

#Preview {
    SplashView()
}
