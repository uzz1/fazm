import Foundation

/// No-op analytics facade.
///
/// DeskPilot ships no analytics. The posthog-ios SDK and its API key are gone;
/// this type survives only so the ~330 call sites spread across 24 files keep
/// compiling without a mechanical edit of every one. Every method below does
/// nothing and every getter returns the "disabled" answer.
///
/// Consequences worth knowing before changing anything here:
/// - `isFeatureEnabled` always returns false, so any surviving feature flag is
///   permanently off. That is the intended default; flags that gated a shipped
///   feature should be removed at the call site, not turned back on here.
/// - `hasOptedOut` returns true, which is the honest answer when nothing is
///   collected. A privacy toggle bound to it will read "opted out".
/// - Do not reintroduce a network client in this file. If DeskPilot ever wants
///   its own telemetry it should be a new, explicitly-consented component.
@MainActor
class PostHogManager {
    static let shared = PostHogManager()

    struct FeatureFlagEvaluation {
        let enabled: Bool
        let resolved: Bool
        let valueDescription: String
    }

    private init() {}

    // MARK: - Initialization

    func initialize() {
        log("Analytics: disabled (no-op facade)")
    }

    // MARK: - User Identification

    func identify() {}

    func setUserProperty(key: String, value: Any) {}

    func identifyAuthUser(userId: String, properties: [String: Any]) {}

    func register(properties: [String: Any]) {}

    // MARK: - Event Tracking

    func track(_ eventName: String, properties: [String: Any]? = nil) {}

    func trackSessionHeartbeat(durationMinutes: Int) {}

    // MARK: - Screen Tracking

    func screen(_ screenName: String, properties: [String: Any]? = nil) {}

    // MARK: - Opt In/Out

    func optIn() {}

    func optOut() {}

    /// Always true: with no collection there is nothing to opt into.
    var hasOptedOut: Bool { true }

    // MARK: - Reset

    func reset() {}

    // MARK: - Feature Flags

    /// Always false. Every flag is permanently off.
    func isFeatureEnabled(_ flag: String) -> Bool { false }

    func getFeatureFlag(_ flag: String) -> Any? { nil }

    func evaluateFeatureFlagAfterReload(_ flag: String, timeout: TimeInterval = 3.0) async -> FeatureFlagEvaluation {
        FeatureFlagEvaluation(enabled: false, resolved: false, valueDescription: "analytics-disabled")
    }

    func reloadFeatureFlags() {}
}

// MARK: - Analytics Events

extension PostHogManager {

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {
        track("Onboarding Step \(stepName) Completed", properties: [
            "step": step
        ])
    }

    func onboardingCompleted() {
        track("Onboarding Completed")
    }

    // MARK: - Authentication Events

    func signInStarted(provider: String) {
        track("Sign In Started", properties: [
            "provider": provider
        ])
    }

    func signInCompleted(provider: String) {
        track("Sign In Completed", properties: [
            "provider": provider
        ])
    }

    func signInFailed(provider: String, error: String) {
        track("Sign In Failed", properties: [
            "provider": provider,
            "error": error
        ])
    }

    func signedOut() {
        track("Signed Out")
    }

    // MARK: - Monitoring Events

    func monitoringStarted() {
        track("Monitoring Started")
    }

    func monitoringStopped() {
        track("Monitoring Stopped")
    }

    func distractionDetected(app: String, windowTitle: String?) {
        var properties: [String: Any] = [
            "app": app
        ]
        if let title = windowTitle {
            properties["window_title"] = title
        }
        track("Distraction Detected", properties: properties)
    }

    func focusRestored(app: String) {
        track("Focus Restored", properties: [
            "app": app
        ])
    }

    // MARK: - Recording Events

    func transcriptionStarted() {
        track("Phone Mic Recording Started")
    }

    func transcriptionStopped(wordCount: Int) {
        track("Phone Mic Recording Stopped", properties: [
            "word_count": wordCount
        ])
    }

    func recordingError(error: String) {
        track("Phone Mic Recording Error", properties: [
            "error": error
        ])
    }

    // MARK: - Permission Events

    func permissionRequested(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Requested", properties: props)
    }

    func permissionGranted(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Granted", properties: props)
    }

    func permissionDenied(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Denied", properties: props)
    }

    func permissionSkipped(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Skipped", properties: props)
    }

    /// Track when ScreenCaptureKit broken state is detected
    func screenCaptureBrokenDetected() {
        track("Screen Capture Broken Detected", properties: [:])
    }

    /// Track when user clicks reset button or notification
    func screenCaptureResetClicked(source: String) {
        track("Screen Capture Reset Clicked", properties: [
            "source": source
        ])
    }

    /// Track when screen capture reset completes
    func screenCaptureResetCompleted(success: Bool) {
        track("Screen Capture Reset Completed", properties: [
            "success": success
        ])
    }


    // MARK: - App Lifecycle Events

    func appLaunched() {
        track("App Launched", properties: [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }

    /// Track first launch with comprehensive system diagnostics
    func firstLaunch(diagnostics: [String: Any]) {
        track("First Launch", properties: diagnostics)
    }

    func appBecameActive() {
        track("App Became Active")
    }

    func appResignedActive() {
        track("App Resigned Active")
    }

    // MARK: - Page/Screen Views (PostHog specific)

    func pageViewed(_ pageName: String) {
        screen(pageName)
        track("Page Viewed", properties: ["page": pageName])
    }

    // MARK: - Conversation Events
    // Note: The event is named "Memory Created" in analytics for historical reasons,
    // but it actually tracks when a conversation/recording is created, not a "memory".
    // This matches Flutter's naming for analytics consistency.

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {
        var properties: [String: Any] = [
            "conversation_id": conversationId,
            "source": source
        ]
        if let duration = durationSeconds {
            properties["duration_seconds"] = duration
        }
        track("Memory Created", properties: properties)
    }

    func memoryDeleted(conversationId: String) {
        track("Memory Deleted", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryShareButtonClicked(conversationId: String) {
        track("Memory Share Button Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryListItemClicked(conversationId: String) {
        track("Memory List Item Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events

    /// Tracks every user-sent message across every surface (floating bar, onboarding
    /// chat, conversation view, popouts). Fires BEFORE the ACP query runs, so this
    /// is the only event guaranteed to capture user text even when the chat agent
    /// later fails at warmup or mid-stream. `message_text` is capped to 1000 chars
    /// to match the other text-bearing events (`chat_agent_query_completed`,
    /// `floating_bar_query_sent`).
    func chatMessageSent(messageLength: Int, hasContext: Bool = false, source: String, messageText: String = "") {
        var props: [String: Any] = [
            "message_length": messageLength,
            "has_context": hasContext,
            "source": source
        ]
        if !messageText.isEmpty {
            props["message_text"] = String(messageText.prefix(1000))
        }
        track("Chat Message Sent", properties: props)
    }

    // MARK: - Search Events

    func searchQueryEntered(query: String) {
        track("Search Query Entered", properties: [
            "query_length": query.count
        ])
    }

    func searchBarFocused() {
        track("Search Bar Focused")
    }

    // MARK: - Settings Events

    func settingsPageOpened() {
        track("Settings Page Opened")
    }

    // MARK: - Account Events

    func deleteAccountClicked() {
        track("Delete Account Clicked")
    }

    func deleteAccountConfirmed() {
        track("Delete Account Confirmed")
    }

    func deleteAccountCancelled() {
        track("Delete Account Cancelled")
    }

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {
        track("Tab Changed", properties: [
            "tab_name": tabName
        ])
    }

    func conversationDetailOpened(conversationId: String) {
        track("Conversation Detail Opened", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {
        var properties: [String: Any] = [:]
        if let id = appId { properties["app_id"] = id }
        if let name = appName { properties["app_name"] = name }
        track("Chat App Selected", properties: properties.isEmpty ? nil : properties)
    }

    func chatCleared() {
        track("Chat Cleared")
    }

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {
        track("Conversation Reprocessed", properties: [
            "conversation_id": conversationId,
            "app_id": appId
        ])
    }

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {
        track("Setting Toggled", properties: [
            "setting": setting,
            "enabled": enabled
        ])
    }

    func languageChanged(language: String) {
        track("Language Changed", properties: [
            "language": language
        ])
    }

    // MARK: - Launch At Login Events

    func launchAtLoginStatusChecked(enabled: Bool) {
        track("Launch At Login Status", properties: [
            "enabled": enabled
        ])
    }

    func launchAtLoginChanged(enabled: Bool, source: String) {
        track("Launch At Login Changed", properties: [
            "enabled": enabled,
            "source": source
        ])
    }

    // MARK: - Feedback Events

    func feedbackOpened(source: String = "modal") {
        track("Feedback Opened", properties: [
            "source": source
        ])
    }

    func feedbackSubmitted(feedbackLength: Int, source: String = "modal") {
        track("Feedback Submitted", properties: [
            "feedback_length": feedbackLength,
            "source": source
        ])
    }

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {
        track("Focus Alert Shown", properties: [
            "app": app
        ])
    }

    func focusAlertDismissed(app: String, action: String) {
        track("Focus Alert Dismissed", properties: [
            "app": app,
            "action": action
        ])
    }

    func taskExtracted(taskCount: Int) {
        track("Task Extracted", properties: [
            "task_count": taskCount
        ])
    }

    func taskPromoted(taskCount: Int) {
        track("Task Promoted", properties: [
            "task_count": taskCount
        ])
    }

    func taskCompleted(source: String?) {
        track("Task Completed", properties: [
            "source": source ?? "unknown"
        ])
    }

    func taskDeleted(source: String?) {
        track("Task Deleted", properties: [
            "source": source ?? "unknown"
        ])
    }

    func taskAdded() {
        track("Task Added")
    }

    func memoryExtracted(memoryCount: Int) {
        track("Memory Extracted", properties: [
            "memory_count": memoryCount
        ])
    }

    func adviceGenerated(category: String?) {
        var properties: [String: Any] = [:]
        if let cat = category { properties["category"] = cat }
        track("Advice Generated", properties: properties.isEmpty ? nil : properties)
    }

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {
        track("App Enabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDisabled(appId: String, appName: String) {
        track("App Disabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDetailViewed(appId: String, appName: String) {
        track("App Detail Viewed", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    // MARK: - Update Events

    func updateCheckStarted() {
        track("Update Check Started")
    }

    func updateAvailable(version: String) {
        track("Update Available", properties: [
            "version": version
        ])
    }

    func updateInstalled(version: String) {
        track("Update Installed", properties: [
            "version": version
        ])
    }

    func nodeBinaryCorrupted(version: String, installMethod: String) {
        track("Node Binary Corrupted", properties: [
            "version": version,
            "install_method": installMethod,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }

    func updateNotFound() {
        track("Update Not Found")
    }

    func updateCheckFailed(error: String, errorDomain: String, errorCode: Int, underlyingError: String? = nil, underlyingDomain: String? = nil, underlyingCode: Int? = nil) {
        var props: [String: Any] = [
            "error": error,
            "error_domain": errorDomain,
            "error_code": errorCode
        ]
        if let underlyingError { props["underlying_error"] = underlyingError }
        if let underlyingDomain { props["underlying_domain"] = underlyingDomain }
        if let underlyingCode { props["underlying_code"] = underlyingCode }
        track("Update Check Failed", properties: props)
    }

    // MARK: - Notification Events

    func notificationSent(notificationId: String, title: String, assistantId: String) {
        track("Notification Sent", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationClicked(notificationId: String, title: String, assistantId: String) {
        track("Notification Clicked", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationDismissed(notificationId: String, title: String, assistantId: String) {
        track("Notification Dismissed", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationWillPresent(notificationId: String, title: String) {
        track("Notification Will Present", properties: [
            "notification_id": notificationId,
            "title": title
        ])
    }

    func notificationDelegateReady() {
        track("Notification Delegate Ready")
    }

    // MARK: - Menu Bar Events

    func menuBarOpened() {
        track("Menu Bar Opened")
    }

    func menuBarActionClicked(action: String) {
        track("Menu Bar Action Clicked", properties: [
            "action": action
        ])
    }

    // MARK: - Tier Events

    func tierChanged(tier: Int, reason: String) {
        track("Tier Changed", properties: [
            "tier": tier,
            "reason": reason
        ])
    }

    func chatBridgeModeChanged(from oldMode: String, to newMode: String) {
        track("chat_bridge_mode_changed", properties: [
            "from": oldMode,
            "to": newMode
        ])
    }

    func claudeCliCredentialsDetected() {
        track("claude_cli_credentials_detected")
    }

    // MARK: - Settings State

    func settingsStateTracked(screenshotsEnabled: Bool, memoryExtractionEnabled: Bool, memoryNotificationsEnabled: Bool) {
        track("Settings State", properties: [
            "screenshots_enabled": screenshotsEnabled,
            "memory_extraction_enabled": memoryExtractionEnabled,
            "memory_notifications_enabled": memoryNotificationsEnabled
        ])
    }

    /// Comprehensive all-settings snapshot (fired on app launch, at most once per day)
    func allSettingsStateTracked(properties: [String: Any]) {
        track("All Settings State", properties: properties)
    }

    // MARK: - Display Info

    func displayInfoTracked(info: [String: Any]) {
        track("Display Info", properties: info)
    }
}
