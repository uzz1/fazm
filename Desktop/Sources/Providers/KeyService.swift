import Foundation

/// Resolves API keys for the third-party services the app still talks to.
///
/// This used to POST `${FAZM_BACKEND_URL}/v1/keys` with a Firebase ID token and
/// receive Fazm's own vendor keys. DeskPilot has no account and no token, so
/// that endpoint is unreachable by design and the call is gone. Keys now come
/// from the process environment (`.env.app`) only, which is where a local-first
/// build should read its own credentials from anyway.
///
/// The async surface (`fetchKeys`, `ensureKeys`, `refetchAnthropicKey`) is kept
/// because callers await it on paths that used to race the network. Reading
/// `environ` is synchronous, so these now just resolve immediately.
final class KeyService {
    static let shared = KeyService()

    var anthropicAPIKey: String? { Self.nonEmptyEnv("ANTHROPIC_API_KEY") }
    var deepgramAPIKey: String? { Self.nonEmptyEnv("DEEPGRAM_API_KEY") }
    var geminiAPIKey: String? { Self.nonEmptyEnv("GEMINI_API_KEY") }
    var elevenlabsAPIKey: String? { Self.nonEmptyEnv("ELEVENLABS_API_KEY") }

    /// Resolve the ElevenLabs API key. Mirrors `TranscriptionService.resolveDeepgramKey`
    /// so callers keep the same lookup shape.
    static func resolveElevenLabsKey() async throws -> String {
        if let k = KeyService.shared.elevenlabsAPIKey { return k }
        throw NSError(
            domain: "KeyService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ELEVENLABS_API_KEY not set"]
        )
    }

    private init() {}

    /// No-op retained for call-site compatibility: keys are read from the
    /// environment on every access, so there is nothing to fetch.
    func fetchKeys() async {}

    /// No-op retained for call-site compatibility. Always reports "unchanged"
    /// because the environment is the only source and it does not rotate
    /// mid-process.
    @discardableResult
    func refetchAnthropicKey() async -> Bool {
        log("KeyService: refetchAnthropicKey() — keys come from the environment, nothing to refetch")
        return false
    }

    /// No-op retained for call-site compatibility.
    func ensureKeys(timeout: TimeInterval = 10) async {
        _ = timeout
    }

    // MARK: - Private Helpers

    private static func nonEmptyEnv(_ key: String) -> String? {
        guard let ptr = getenv(key) else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }
}
