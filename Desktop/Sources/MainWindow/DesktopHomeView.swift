import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()

    // Settings sidebar state
    @State private var selectedSettingsSection: SettingsContentView.SettingsSection = .conversationHistory
    @State private var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection? = nil
    @State private var highlightedSettingId: String? = nil

    var body: some View {
        Group {
            // No sign-in gate: the user is `LocalUser`, always, so the first
            // thing a fresh launch sees is onboarding.
            if !appState.hasCompletedOnboarding {
                if shouldSkipOnboarding() {
                    Color.clear.onAppear {
                        log("DesktopHomeView: --skip-onboarding flag detected, skipping onboarding")
                        appState.hasCompletedOnboarding = true
                    }
                } else {
                    OnboardingView(appState: appState, chatProvider: viewModelContainer.chatProvider, onComplete: nil)
                        .onAppear {
                            log("DesktopHomeView: Showing OnboardingView")
                        }
                }
            } else {
                settingsContent
                    .onAppear {
                        log("DesktopHomeView: Showing settings (onboarded)")
                        appState.checkAllPermissions()

                        // Set up floating control bar
                        FloatingControlBarManager.shared.setup(appState: appState, chatProvider: viewModelContainer.chatProvider)
                        if FloatingControlBarManager.shared.isEnabled {
                            FloatingControlBarManager.shared.show()
                        }

                        // EXPERIMENT 2026-05-28: skip window restoration to test
                        // whether restored detached windows are what drives the
                        // shared-main-thread relayout storm. Sample shows 7
                        // NSHostingView.layout calls 60Hz, matching the count of
                        // restored windows + bar + main. If with NO restored
                        // windows the storm is gone, the trigger is somewhere
                        // in the restoration path (likely a shared @Published
                        // mutated when a restored window observes it).
                        if UserDefaults.standard.bool(forKey: "fazm_restore_detached_windows_2028") {
                            DetachedChatWindowController.shared.restoreWindows(chatProvider: viewModelContainer.chatProvider)
                        } else {
                            log("DetachedChatWindowController: restoration DISABLED (experiment)")
                        }

                        // Set up push-to-talk voice input
                        if let barState = FloatingControlBarManager.shared.barState {
                            PushToTalkManager.shared.setup(barState: barState)
                        }

                        // After onboarding, close the main window — just show floating bar
                        let justOnboarded = UserDefaults.standard.bool(forKey: "onboardingJustCompleted")
                        if justOnboarded {
                            UserDefaults.standard.set(false, forKey: "onboardingJustCompleted")
                            log("DesktopHomeView: Post-onboarding — closing main window, showing floating bar only")
                            // Ensure floating bar is visible
                            if !FloatingControlBarManager.shared.isEnabled {
                                FloatingControlBarManager.shared.show()
                            }
                            DispatchQueue.main.async {
                                for window in NSApp.windows {
                                    if window.title.hasPrefix("Fazm") {
                                        window.orderOut(nil)
                                    }
                                }
                            }
                        }
                    }
                    .task {
                        await viewModelContainer.loadAllData()
                    }
            }
        }
        .background(FazmColors.backgroundPrimary)
        .frame(minWidth: 900, minHeight: 600)
        .tint(FazmColors.purplePrimary)
        // A `.task(id: authState.isSignedIn)` used to sit here running the hard
        // subscription gate the moment auth flipped to signed-in. Both halves
        // are gone: there is no sign-in to key a task on, and the Stripe status
        // endpoint it called needed an ID token no local user can mint.
        // Observe ChatProvider flags
        .onReceive(viewModelContainer.chatProvider.$needsBrowserExtensionSetup) { needs in
            if needs {
                viewModelContainer.chatProvider.needsBrowserExtensionSetup = false
                BrowserExtensionSetupWindowController.shared.show(
                    chatProvider: viewModelContainer.chatProvider,
                    onComplete: {
                        // Route the continuation back to the chat surface the
                        // user was actually using (floating bar, pop-out, main
                        // chat, or onboarding) instead of always dumping it in
                        // the floating bar. Fix for the "AI loses context after
                        // extension install" bug reported by amabdig@gmail.com
                        // 2026-05-13.
                        viewModelContainer.chatProvider.retryAfterBrowserSetup()
                    },
                    source: "chat_interception"
                )
            }
        }
        // Paywall window is now triggered directly in ChatProvider.sendMessage()
        // so it works from all surfaces (floating bar, detached window, main window)
        .onAppear {
            log("DesktopHomeView: View appeared - hasCompletedOnboarding=\(appState.hasCompletedOnboarding)")
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    if window.title.hasPrefix("Fazm") {
                        window.minSize = NSSize(width: 900, height: 600)
                    }
                }
            }
        }
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selectedSection: $selectedSettingsSection,
                selectedAdvancedSubsection: $selectedAdvancedSubsection,
                highlightedSettingId: $highlightedSettingId,
                appState: appState
            )
            .fixedSize(horizontal: true, vertical: false)
            .clipped()

            // Main content area with rounded container
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(FazmColors.backgroundSecondary.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(FazmColors.backgroundTertiary.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 4)

                SettingsPage(
                    appState: appState,
                    selectedSection: $selectedSettingsSection,
                    selectedAdvancedSubsection: $selectedAdvancedSubsection,
                    highlightedSettingId: $highlightedSettingId,
                    chatProvider: viewModelContainer.chatProvider
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        // Handle navigation from floating bar gear icon
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFloatingBarSettings)) { _ in
            selectedSettingsSection = .shortcuts
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAIChatSettings)) { _ in
            selectedSettingsSection = .advanced
            selectedAdvancedSubsection = .aiChat
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("navigateToSetting"))) { notification in
            guard let settingId = notification.userInfo?["settingId"] as? String,
                  let item = SettingsSearchItem.allSearchableItems.first(where: { $0.settingId == settingId }) else { return }
            selectedSettingsSection = item.section
            if let sub = item.advancedSubsection {
                selectedAdvancedSubsection = sub
            }
        }
    }
}

#Preview {
    DesktopHomeView()
}
