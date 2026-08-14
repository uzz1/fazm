import Foundation

/// Publishes the DeskPilot local-UI lease that Hermes reads before it will
/// admit any turn.
///
/// The seam this closes: `acp_adapter/session.py::_deskpilot_admit_ui` reads
/// `~/.deskpilot/run/ui-lease` through `LiveUILeaseReader` and refuses to
/// create, fork, restore, or prompt a session without it. Nothing wrote that
/// file, so `session/new` always failed with "DeskPilot UI admission denied".
///
/// Why the *app* and not the bridge: the parent policy server takes the PID of
/// its socket peer, requires the registration to claim that same PID, and then
/// resolves that PID's executable and checks its code-signing identifier
/// against a closed allowlist. Only this process can satisfy that — a Node or
/// Python child would present its own interpreter's signature. So the socket
/// connection must originate here.
///
/// Everything below is written to match the reader, which is the authority:
///   * the record has exactly the keys `uiLease`, `pid`, `expiresAt`;
///   * `expiresAt` is strict RFC3339 and strictly inside a 300-second future
///     window (published shorter than the server's grant, see `publishWindow`);
///   * the file is a regular file, owner-only mode 0600, not a symlink;
///   * every ancestor up to `~/.deskpilot` is a real directory owned by this
///     user with no group or other permission bits.
enum DeskPilotUILease {

  // MARK: - Contract constants

  /// How often the lease is re-registered and rewritten. The parent grants five
  /// minutes; renewing far inside that leaves room for a missed tick.
  static let renewalInterval: TimeInterval = 60

  /// How far ahead the published `expiresAt` is allowed to sit. The reader
  /// rejects anything more than 300 s out, so publishing the server's full
  /// five-minute grant verbatim would sit exactly on the boundary and any clock
  /// jitter would fail it closed. A shorter published validity is always safe:
  /// it is re-published every `renewalInterval`.
  static let publishWindow: TimeInterval = 240

  /// Bounded so a wedged or absent policy server can never block the caller.
  static let socketTimeout: TimeInterval = 2.0

  private static let queue = DispatchQueue(label: "com.fazm.deskpilot.ui-lease")
  private static var timer: DispatchSourceTimer?

  /// The live lease token and the moment it stops being usable.
  ///
  /// Retained because the approval path needs it: `approval.list` and
  /// `approval.resolve` are lease-gated, and they are called in response to a
  /// human clicking, not on the publish timer. Guarded by `leaseLock` rather
  /// than `queue` so a caller on any thread can read it without deadlocking
  /// against a publish cycle in flight.
  private static let leaseLock = NSLock()
  private static var currentLease: (token: String, expires: Date)?

  /// The current lease token, or nil if there is none or it has lapsed.
  ///
  /// Nil is a denial, never a prompt to proceed without one: every caller of
  /// this is about to ask the parent for something only a verified UI may ask.
  /// The expiry is checked with a margin so a token cannot be presented in the
  /// instant it stops being valid.
  static func lease(now: Date = Date()) -> String? {
    leaseLock.lock()
    defer { leaseLock.unlock() }
    guard let held = currentLease, held.expires > now.addingTimeInterval(1) else { return nil }
    return held.token
  }

  private static func store(lease: String, expires: Date) {
    leaseLock.lock()
    currentLease = (lease, expires)
    leaseLock.unlock()
  }

  private static func forgetLease() {
    leaseLock.lock()
    currentLease = nil
    leaseLock.unlock()
  }

  /// Parse an RFC3339 UTC timestamp in one of the two shapes the parent emits.
  ///
  /// `PolicyServer.timestamp` is `datetime.isoformat()` with the offset
  /// rewritten to `Z`, so it carries fractional seconds whenever the microsecond
  /// field is non-zero — which is nearly always. It is dropped only on an exact
  /// second. Both forms must parse; accepting only the fraction-free one
  /// silently rejected every real grant and the lease was never published.
  ///
  /// Still deliberately not `ISO8601DateFormatter` with lenient options: these
  /// timestamps gate an authorization, so an offset, a space separator, or a
  /// missing `Z` should fail rather than be guessed at. Note this is the
  /// *reader*; `rfc3339` below is the writer and must stay fraction-free,
  /// because Hermes' own validator accepts only that shape.
  static func parseRFC3339(_ value: String) -> Date? {
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let parsed = formatter.date(from: value) { return parsed }
    }
    return nil
  }

  // MARK: - Paths

  static var runDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deskpilot/run")
  }

  static var leaseURL: URL { runDirectory.appendingPathComponent("ui-lease") }
  static var socketURL: URL { runDirectory.appendingPathComponent("policy.sock") }

  // MARK: - Lifecycle

  /// Begin publishing, if DeskPilot offline mode is enabled.
  ///
  /// Gated on the same `deskpilotOfflineEnabled` default as
  /// `ACPBridge.deskpilotEnvironment()`: a stock Fazm build must not open a
  /// socket it has no reason to touch.
  static func start(defaults: UserDefaults = .standard) {
    guard defaults.bool(forKey: "deskpilotOfflineEnabled") else { return }
    queue.async {
      guard timer == nil else { return }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: renewalInterval, leeway: .seconds(5))
      source.setEventHandler { _ = publishOnce() }
      timer = source
      source.resume()
    }
  }

  /// Stop publishing and remove the lease. A stale file cannot outlive the
  /// process that owns the PID inside it.
  static func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
      try? FileManager.default.removeItem(at: leaseURL)
    }
  }

  // MARK: - One publish cycle

  /// Registers with the policy server and rewrites the lease file.
  /// Returns the published lease token, or nil with the reason on stderr.
  ///
  /// A failed registration forgets the retained token before returning. Holding
  /// a token whose grant we could not renew would let the approval path present
  /// credentials it can no longer show are live.
  @discardableResult
  static func publishOnce() -> String? {
    do {
      try ensurePrivateDirectory(runDirectory)
    } catch {
      fputs("[deskpilot] ui-lease: run directory unusable: \(error)\n", stderr)
      return nil
    }

    guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
      fputs("[deskpilot] ui-lease: bundle has no identifier\n", stderr)
      forgetLease()
      return nil
    }

    let grant: (token: String, expires: Date)
    do {
      grant = try register(bundleIdentifier: identifier)
    } catch {
      // Expected while the policy server is not yet listening; the timer retries.
      fputs("[deskpilot] ui-lease: registration failed: \(error)\n", stderr)
      forgetLease()
      return nil
    }

    do {
      try write(lease: grant.token, expiresAt: Date().addingTimeInterval(publishWindow))
    } catch {
      fputs("[deskpilot] ui-lease: publish failed: \(error)\n", stderr)
      forgetLease()
      return nil
    }
    store(lease: grant.token, expires: grant.expires)
    return grant.token
  }

  // MARK: - Errors

  enum LeaseError: Error, CustomStringConvertible {
    case socket(String)
    case refused(rule: String, reason: String)
    case malformedResponse

    var description: String {
      switch self {
      case .socket(let detail): return "socket: \(detail)"
      case .refused(let rule, let reason): return "policy refused (\(rule)): \(reason)"
      case .malformedResponse: return "policy response was not a lease grant"
      }
    }
  }

  // MARK: - Directory

  /// Creates the directory if absent and asserts it is a private, owner-only
  /// real directory. The reader walks these ancestors and refuses group- or
  /// other-readable ones, so a permissive mode here would fail every turn with
  /// a message that points at the lease rather than at the directory.
  static func ensurePrivateDirectory(_ url: URL) throws {
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
      try manager.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    // createDirectory applies posixPermissions to the leaf only, so a freshly
    // created ~/.deskpilot would keep the umask default. Tighten each level.
    var level = url
    let boundary = manager.homeDirectoryForCurrentUser.appendingPathComponent(".deskpilot")
    while true {
      let attributes = try manager.attributesOfItem(atPath: level.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw LeaseError.socket("\(level.path) is not a directory")
      }
      if let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value, mode & 0o077 != 0 {
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: level.path)
      }
      if level.path == boundary.path { return }
      let parent = level.deletingLastPathComponent()
      if parent.path == level.path { return }
      level = parent
    }
  }

  // MARK: - Registration

  /// One `ui.register` round trip over the parent-owned Unix socket.
  ///
  /// Framing lives in `DeskPilotPolicySocket` so registration and the approval
  /// calls cannot drift apart. Returns the token and the parent's own grant
  /// expiry — not the shorter window we publish to the file, which exists only
  /// to keep the reader's 300-second bound off its boundary.
  static func register(bundleIdentifier: String) throws -> (token: String, expires: Date) {
    // The claimed PID must equal the socket peer's PID, and that PID's
    // executable signature is what the parent actually verifies.
    let result = try DeskPilotPolicySocket.call(
      method: "ui.register",
      params: ["bundleID": bundleIdentifier, "pid": Int(getpid())])
    guard
      let token = result["uiLease"] as? String, !token.isEmpty,
      let expiresRaw = result["expiresAt"] as? String,
      let expires = parseRFC3339(expiresRaw)
    else { throw LeaseError.malformedResponse }
    return (token, expires)
  }

  // MARK: - Publication

  /// Strict RFC3339, UTC, no fractional seconds — the shape
  /// `deskpilot_hermes.validation._RFC3339` accepts.
  static func rfc3339(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }

  /// Writes the record the reader expects: exactly three keys, mode 0600, and
  /// swapped into place so a reader never observes a partial file.
  static func write(lease: String, expiresAt: Date) throws {
    let record: [String: Any] = [
      "uiLease": lease,
      "pid": Int(getpid()),
      "expiresAt": rfc3339(expiresAt),
    ]
    let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    let staged = runDirectory.appendingPathComponent(".ui-lease.\(getpid()).staged")
    let manager = FileManager.default
    guard manager.createFile(atPath: staged.path, contents: encoded,
                             attributes: [.posixPermissions: 0o600])
    else { throw LeaseError.socket("could not stage \(staged.path)") }
    do {
      // rename(2), not replaceItem: it must stay the same inode-swap the
      // reader's dev/ino recheck tolerates, and must not leave a temp file
      // behind on failure.
      guard rename(staged.path, leaseURL.path) == 0 else {
        throw LeaseError.socket("rename() \(errno)")
      }
    } catch {
      try? manager.removeItem(at: staged)
      throw error
    }
  }
}
