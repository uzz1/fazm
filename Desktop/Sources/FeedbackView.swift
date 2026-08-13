import SwiftUI

/// Window controller for the feedback dialog
@MainActor
class FeedbackWindow {
    private static var window: NSWindow?

    /// Records a user report locally. The Sentry upload this used to perform was
    /// removed with the SDK; the app log is now the only destination.
    static func sendSilently() {
        AnalyticsManager.shared.feedbackOpened(source: "silent")
        AnalyticsManager.shared.feedbackSubmitted(feedbackLength: 0, source: "silent")
        log("User report recorded locally (silent; no remote destination)")
    }

    static func show(userEmail: String? = nil) {
        // Close existing window if any
        window?.close()

        // Track feedback opened
        AnalyticsManager.shared.feedbackOpened()

        let feedbackView = FeedbackView(userEmail: userEmail) {
            window?.close()
            window = nil
        }

        let hostingController = NSHostingController(rootView: feedbackView.withFontScaling())

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Report Issue"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 400, height: 300))
        newWindow.center()
        newWindow.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.level = .floating

        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI view for collecting user feedback and sending logs
struct FeedbackView: View {
    let userEmail: String?
    let onDismiss: () -> Void

    @State private var feedbackText: String = ""
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var isSubmitting: Bool = false
    @State private var showSuccess: Bool = false

    init(userEmail: String?, onDismiss: @escaping () -> Void) {
        self.userEmail = userEmail
        self.onDismiss = onDismiss
        _email = State(initialValue: userEmail ?? "")
        _name = State(initialValue: AuthService.shared.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showSuccess {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 48)
                        .foregroundColor(.green)

                    Text("Report sent!")
                        .font(.headline)

                    Text("We'll look into this issue.")
                        .foregroundColor(.secondary)

                    Button("Close") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Report an Issue")
                    .font(.headline)

                Text("App logs will be included automatically. Optionally describe what went wrong.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $feedbackText)
                    .font(.body)
                    .frame(minHeight: 100)
                    .border(Color.gray.opacity(0.3), width: 1)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Your name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("your@email.com", text: $email)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Send Report") {
                        submitFeedback()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }

    private func submitFeedback() {
        isSubmitting = true

        let message = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)

        AnalyticsManager.shared.feedbackSubmitted(feedbackLength: message.count)

        log("User report recorded locally (message: \(message.isEmpty ? "none" : "yes")); no remote destination")

        withAnimation {
            showSuccess = true
            isSubmitting = false
        }
    }
}
