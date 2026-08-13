import Foundation

/// The one and only user of this build.
///
/// DeskPilot has no accounts, no sign-in and no network identity. Exactly one
/// person runs it on exactly one machine, so "who is the user" is a constant
/// rather than something to be established at launch. This replaces the
/// `AuthState` / `AuthService` pair that used to answer the same questions from
/// a Firebase session.
///
/// The name is a *local preference*, not an account attribute — the assistant
/// greets the user with it and the model is told it in the system prompt. It is
/// set by the user in conversation (`ChatToolExecutor` calls
/// `updateGivenName`) and read back here. Nothing about it leaves the machine.
enum LocalUser {
    // MARK: - Identity

    /// Stable synthetic identifier for the local user.
    ///
    /// This is what `users/<id>/fazm.db` is keyed on, so it must never change
    /// between launches: changing it orphans the user's chat history, cron jobs
    /// and cron runs. It is deliberately *not* a UUID — a UUID would be
    /// generated per install and could drift — and deliberately not the old
    /// Firebase UID, which was a remote identifier for a service that is gone.
    /// See `AppDatabase.adoptLegacyUserDirectoryIfNeeded` for how the pre-fork
    /// Firebase-UID directory is carried across to this id.
    static let id = "local"

    /// There is no account, so there is no email. Kept as a named constant so
    /// the handful of callers that used to pass `AuthState.shared.userEmail`
    /// (the feedback reporter prefilling a "from" field) read as deliberate
    /// rather than as an oversight.
    static let email: String? = nil

    // MARK: - Name

    private static let kGivenName = "user_givenName"
    private static let kDisplayName = "user_displayName"

    /// The user's full name, or "" when they have never given one.
    /// Callers branch on `.isEmpty` to fall back to a generic greeting.
    static var displayName: String {
        UserDefaults.standard.string(forKey: kDisplayName) ?? ""
    }

    /// The user's first name, or "" when they have never given one.
    static var givenName: String {
        UserDefaults.standard.string(forKey: kGivenName) ?? ""
    }

    /// Record the name the user just told us. Writes both the given name and
    /// the display name so `displayName.isEmpty` — the check every greeting
    /// site uses to decide whether it knows the user — becomes false.
    static func updateGivenName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(trimmed, forKey: kGivenName)
        if (defaults.string(forKey: kDisplayName) ?? "").isEmpty {
            defaults.set(trimmed, forKey: kDisplayName)
        }
        log("LocalUser: given name set to \(trimmed)")
    }
}
