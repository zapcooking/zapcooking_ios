import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen cooking mode: one direction at a time, snapshotted scale,
/// keep-awake while this screen is visible, add-timer via the 1.8a sheet.
///
/// Concern 1.8b. **iOS-original, not a port.** Android's `RecipeDetailScreen`
/// has a "Start cooking" button but `Navigation` passes `onStartCooking = null`,
/// so that button never renders. There is no reference implementation and no
/// golden tests.
///
/// Ingredients live in a **collapsible bottom panel** on every step (not a
/// dedicated first page, not a swipe-only sheet). A first page would send the
/// cook back off the current step to check a quantity — the thing this screen
/// exists to avoid. A swipe-up sheet without a tap target fails the same way
/// pager swipes fail with messy hands. The panel is collapsed by default so a
/// long step (or a 15-step recipe) keeps the direction as the hero; the handle
/// is a large tap target labeled with the ingredient count.
struct CookModeView: View {
    @State private var viewModel: CookModeViewModel
    @State private var timers: CookingTimerStore
    @State private var showTimerSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: CookModeSession,
        timers: CookingTimerStore? = nil,
        wakeLock: CookWakeLock? = nil
    ) {
        _viewModel = State(
            initialValue: CookModeViewModel(
                session: session,
                wakeLock: wakeLock ?? .shared
            )
        )
        _timers = State(initialValue: timers ?? .shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if viewModel.hasSteps {
                pager
            } else {
                emptySteps
            }
        }
        .background(Color.wispBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .overlay {
            TimerCompletionOverlay(
                timer: timers.completion,
                onDismiss: { timers.dismissCompletion() }
            )
        }
        .sheet(isPresented: $showTimerSheet) {
            CookingUtilitiesSheet(
                store: timers,
                onDismiss: { showTimerSheet = false }
            )
        }
        .onAppear { viewModel.onAppear(phase: scenePhase) }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            viewModel.handleScenePhase(phase)
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            viewModel.handleTerminate()
        }
        #endif
        .accessibilityIdentifier("cook-mode-root")
        .interactiveDismissDisabled()
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Exit") { dismiss() }
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .frame(minWidth: 56, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("cook-mode-exit")
            Text(viewModel.session.title)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(viewModel.stepPositionLabel)
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .accessibilityIdentifier("cook-mode-step-label")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: Binding(
            get: { viewModel.stepIndex },
            set: { viewModel.stepIndex = $0 }
        )) {
            ForEach(Array(viewModel.session.directions.enumerated()), id: \.offset) { index, text in
                stepPage(index: index, text: text)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func stepPage(index: Int, text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(index + 1)")
                    .font(AppFont.titleLarge)
                    .foregroundStyle(Color.wispBackground)
                    .frame(width: 44, height: 44)
                    .background(Color.wispPrimary, in: Circle())
                Text(text)
                    .font(AppFont.scaled(22))
                    .foregroundStyle(Color.wispOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showTimerSheet = true
                } label: {
                    Label("Add timer", systemImage: "timer")
                        .font(AppFont.titleMedium)
                        .foregroundStyle(Color.wispOnSurface)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 56)
                        .background(
                            Color.wispSurfaceVariant.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cook-mode-add-timer")
                .accessibilityHint("Opens the timer sheet. Duration is not read from the step.")
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var emptySteps: some View {
        VStack {
            Spacer()
            Text("No directions")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom chrome

    /// Timer bar, ingredients panel, pager buttons. The bar sits in this
    /// stack (not over the pager chrome) so a running timer stays visible
    /// while paging and cannot cover Back / Next.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            FloatingTimerBar(
                store: timers,
                isSheetVisible: showTimerSheet,
                onExpand: { showTimerSheet = true }
            )
            ingredientsPanel
            pagerButtons
        }
        .background(Color.wispBackground)
    }

    private var ingredientsPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.ingredientsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.ingredientsExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                    Text(ingredientsHandleTitle)
                        .font(AppFont.titleMedium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if abs(viewModel.session.scale - 1.0) >= 0.001 {
                        Text(RecipeDetailView.scaleLabel(viewModel.session.scale))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(Color.wispPrimary)
                    }
                }
                .foregroundStyle(Color.wispOnSurface)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cook-mode-ingredients")
            .accessibilityHint(
                viewModel.ingredientsExpanded
                    ? "Hides the ingredient list"
                    : "Shows scaled ingredients for this recipe"
            )

            if viewModel.ingredientsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let servings = viewModel.session.scaledServings {
                            Text("Servings: \(servings)")
                                .font(AppFont.bodyMedium)
                                .foregroundStyle(Color.wispOnSurfaceVariant)
                                .padding(.bottom, 4)
                        }
                        if viewModel.session.scaledIngredients.isEmpty {
                            Text("No ingredients")
                                .font(AppFont.bodyLarge)
                                .foregroundStyle(Color.wispOnSurfaceVariant)
                        } else {
                            ForEach(Array(viewModel.session.scaledIngredients.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(Color.wispPrimary)
                                    Text(line)
                                        .font(AppFont.bodyLarge)
                                        .foregroundStyle(Color.wispOnSurface)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .accessibilityIdentifier("cook-mode-ingredients-list")
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.35))
    }

    private var ingredientsHandleTitle: String {
        let count = viewModel.session.scaledIngredients.count
        if count == 0 { return "Ingredients" }
        return "Ingredients · \(count)"
    }

    private var pagerButtons: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.goBack) {
                Label("Back", systemImage: "chevron.left")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(viewModel.canGoBack ? Color.wispOnSurface : Color.wispOnSurfaceVariant.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
                    .background(
                        Color.wispSurfaceVariant.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoBack)
            .accessibilityIdentifier("cook-mode-back")

            Button(action: viewModel.goForward) {
                HStack(spacing: 6) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
                .font(AppFont.titleMedium)
                .foregroundStyle(viewModel.canGoForward ? Color.wispBackground : Color.wispOnSurfaceVariant.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .background(
                    viewModel.canGoForward
                        ? Color.wispPrimary
                        : Color.wispSurfaceVariant.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoForward)
            .accessibilityLabel("Next")
            .accessibilityIdentifier("cook-mode-next")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }
}
