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
      return nil
    }

    let token: String
    do {
      token = try register(bundleIdentifier: identifier)
    } catch {
      // Expected while the policy server is not yet listening; the timer retries.
      fputs("[deskpilot] ui-lease: registration failed: \(error)\n", stderr)
      return nil
    }

    do {
      try write(lease: token, expiresAt: Date().addingTimeInterval(publishWindow))
    } catch {
      fputs("[deskpilot] ui-lease: publish failed: \(error)\n", stderr)
      return nil
    }
    return token
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
  static func register(bundleIdentifier: String) throws -> String {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LeaseError.socket("socket() \(errno)") }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketURL.path
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw LeaseError.socket("socket path too long") }
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = strlcpy(destination, path, capacity)
      }
    }

    var timeout = timeval(
      tv_sec: Int(socketTimeout),
      tv_usec: Int32((socketTimeout - floor(socketTimeout)) * 1_000_000))
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw LeaseError.socket("connect() \(errno) at \(path)") }

    // The claimed PID must equal the socket peer's PID, and that PID's
    // executable signature is what the parent actually verifies.
    let request: [String: Any] = [
      "protocol": "deskpilot.policy",
      "version": 1,
      "requestID": UUID().uuidString.lowercased(),
      "method": "ui.register",
      "params": ["bundleID": bundleIdentifier, "pid": Int(getpid())],
    ]
    var frame = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    frame.append(0x0A)
    try writeAll(descriptor, frame)

    let line = try readLine(descriptor)
    guard
      let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any]
    else { throw LeaseError.malformedResponse }
    if let error = decoded["error"] as? [String: Any] {
      throw LeaseError.refused(
        rule: error["ruleID"] as? String ?? "unknown",
        reason: error["reason"] as? String ?? "")
    }
    guard
      let result = decoded["result"] as? [String: Any],
      let token = result["uiLease"] as? String, !token.isEmpty
    else { throw LeaseError.malformedResponse }
    return token
  }

  private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
    var sent = 0
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      while sent < buffer.count {
        let written = Darwin.write(descriptor, base.advanced(by: sent), buffer.count - sent)
        if written <= 0 {
          if errno == EINTR { continue }
          throw LeaseError.socket("write() \(errno)")
        }
        sent += written
      }
    }
  }

  /// Reads one newline-delimited frame. The parent replies with exactly one
  /// line and then closes, so a short read is not a frame boundary.
  private static func readLine(_ descriptor: Int32) throws -> Data {
    var accumulated = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while accumulated.count <= 262_144 {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw LeaseError.socket("read() \(errno)")
      }
      if count == 0 { break }
      accumulated.append(contentsOf: chunk[0..<count])
      if let terminator = accumulated.firstIndex(of: 0x0A) {
        return accumulated[accumulated.startIndex..<terminator]
      }
    }
    throw LeaseError.malformedResponse
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
