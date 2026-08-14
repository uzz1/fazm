import Foundation

/// One newline-delimited request/response exchange over the parent-owned
/// `policy.sock`.
///
/// Factored out of `DeskPilotUILease` rather than copied: the lease
/// registration and the approval calls must speak the identical framing to the
/// identical socket, and two implementations of one wire format is how they
/// drift apart. Nothing here decides anything — it moves frames.
enum DeskPilotPolicySocket {

  static let timeout: TimeInterval = 2.0
  static let maximumFrame = 262_144

  enum SocketError: Error, CustomStringConvertible {
    case socket(String)
    case refused(rule: String, reason: String)
    case malformedResponse

    var description: String {
      switch self {
      case .socket(let detail): return "socket: \(detail)"
      case .refused(let rule, let reason): return "policy refused (\(rule)): \(reason)"
      case .malformedResponse: return "policy response was malformed"
      }
    }
  }

  static var socketURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".deskpilot/run/policy.sock")
  }

  /// Send one request and return its `result` object.
  ///
  /// An `error` branch is thrown as `.refused`, never returned as an empty
  /// success — a caller that reads a missing field as "no" would turn a policy
  /// error into a silent wrong answer.
  static func call(method: String, params: [String: Any]) throws -> [String: Any] {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketError.socket("socket() \(errno)") }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketURL.path
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw SocketError.socket("socket path too long") }
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = strlcpy(destination, path, capacity)
      }
    }

    var deadline = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw SocketError.socket("connect() \(errno) at \(path)") }

    let request: [String: Any] = [
      "protocol": "deskpilot.policy",
      "version": 1,
      "requestID": UUID().uuidString.lowercased(),
      "method": method,
      "params": params,
    ]
    var frame = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    frame.append(0x0A)
    try writeAll(descriptor, frame)

    let line = try readFrame(descriptor)
    guard let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      throw SocketError.malformedResponse
    }
    if let error = decoded["error"] as? [String: Any] {
      throw SocketError.refused(
        rule: error["ruleID"] as? String ?? "unknown",
        reason: error["reason"] as? String ?? "")
    }
    guard let result = decoded["result"] as? [String: Any] else {
      throw SocketError.malformedResponse
    }
    return result
  }

  static func writeAll(_ descriptor: Int32, _ data: Data) throws {
    var sent = 0
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      while sent < buffer.count {
        let written = Darwin.write(descriptor, base.advanced(by: sent), buffer.count - sent)
        if written <= 0 {
          if errno == EINTR { continue }
          throw SocketError.socket("write() \(errno)")
        }
        sent += written
      }
    }
  }

  /// Reads one newline-delimited frame. The parent replies with exactly one
  /// line, so a short read is not a frame boundary.
  static func readFrame(_ descriptor: Int32) throws -> Data {
    var accumulated = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while accumulated.count <= maximumFrame {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw SocketError.socket("read() \(errno)")
      }
      if count == 0 { break }
      accumulated.append(contentsOf: chunk[0..<count])
      if let terminator = accumulated.firstIndex(of: 0x0A) {
        return accumulated[accumulated.startIndex..<terminator]
      }
    }
    throw SocketError.malformedResponse
  }
}

/// What the *registry* says a pending action is.
///
/// Every field here comes from the parent policy server's `approval.list`,
/// which answers from `ActionRegistry.resolve` — the same resolution that
/// authorized the action. None of it is model-authored. That is the whole
/// point: the model that requested this action reads untrusted screen text and
/// web content, so its own description of what it is about to do is not
/// evidence of anything and is never shown.
struct DeskPilotPendingAction: Equatable, Sendable {
  let pendingApprovalID: String
  let traceID: String
  let entryPoint: String
  let sender: String?
  let actionID: String
  let actionVersion: Int
  let inputs: [String: String]
  let risk: String
  let verdict: String
  let ruleID: String
  let reason: String
  let actionDigest: String
  let expiresAt: Date

  /// The inputs rendered for display, sorted so the same action always reads
  /// the same way. Values are stringified at parse time (see `parse`) so no
  /// nested structure can smuggle in something that renders as UI chrome.
  var displayInputs: [(String, String)] {
    inputs.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }

  /// Strict parse of one `ApprovalItem`. Any missing or wrong-typed field
  /// yields nil, and a nil pending action is never shown or approved — an item
  /// we cannot fully read is one we cannot honestly describe to the user.
  static func parse(_ raw: Any) -> DeskPilotPendingAction? {
    guard
      let item = raw as? [String: Any],
      let pendingApprovalID = item["pendingApprovalID"] as? String,
      let traceID = item["traceID"] as? String,
      let entryPoint = item["entryPoint"] as? String,
      let actionID = item["actionID"] as? String,
      let actionVersion = item["actionVersion"] as? Int,
      let inputs = item["inputs"] as? [String: Any],
      let decision = item["decision"] as? [String: Any],
      let risk = decision["risk"] as? String,
      let verdict = decision["verdict"] as? String,
      let ruleID = decision["ruleID"] as? String,
      let reason = decision["reason"] as? String,
      let actionDigest = item["actionDigest"] as? String,
      let expiresRaw = item["expiresAt"] as? String,
      let expiresAt = DeskPilotUILease.parseRFC3339(expiresRaw)
    else { return nil }

    var flattened: [String: String] = [:]
    for (key, value) in inputs {
      flattened[key] = describeInput(value)
    }

    return DeskPilotPendingAction(
      pendingApprovalID: pendingApprovalID, traceID: traceID, entryPoint: entryPoint,
      sender: item["sender"] as? String, actionID: actionID, actionVersion: actionVersion,
      inputs: flattened, risk: risk, verdict: verdict, ruleID: ruleID, reason: reason,
      actionDigest: actionDigest, expiresAt: expiresAt)
  }

  /// Render one validated input value as a single line of plain text.
  ///
  /// Newlines and control characters are collapsed, and the result is capped.
  /// An input is registry-validated, but it is still a *value* — it must not be
  /// able to lay out lines that read as separate UI rows, or as a policy
  /// verdict the system did not make.
  static func describeInput(_ value: Any) -> String {
    let raw: String
    switch value {
    case let text as String: raw = text
    case let flag as Bool: raw = flag ? "true" : "false"
    case let number as NSNumber: raw = number.stringValue
    case is NSNull: raw = "null"
    default:
      let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
      raw = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "(unreadable)"
    }
    let flattened = raw.unicodeScalars.map { scalar -> String in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined()
    return flattened.count > 240 ? String(flattened.prefix(240)) + "…" : flattened
  }
}

/// The parent-socket half of the approval path.
///
/// These are the calls only this process can make: `approval.list` and
/// `approval.resolve` both require a UI lease, and the parent verifies the
/// lease against the code signature of its socket peer's PID. A bridge or
/// Hermes child presenting the same token would be refused, because it would
/// present its interpreter's signature.
enum DeskPilotApprovalService {

  /// Every unresolved, unexpired pending approval the parent is holding.
  static func list(lease: String) throws -> [DeskPilotPendingAction] {
    let result = try DeskPilotPolicySocket.call(method: "approval.list", params: ["uiLease": lease])
    guard let items = result["items"] as? [Any] else {
      throw DeskPilotPolicySocket.SocketError.malformedResponse
    }
    return items.compactMap(DeskPilotPendingAction.parse)
  }

  /// Look up one pending approval by ID.
  ///
  /// Returns nil when the parent is not holding it — expired, already
  /// resolved, cancelled, or never existed. Nil means deny: there is nothing
  /// to consent to.
  static func find(lease: String, pendingApprovalID: String) throws -> DeskPilotPendingAction? {
    try list(lease: lease).first { $0.pendingApprovalID == pendingApprovalID }
  }

  /// Record the human's decision with the parent.
  ///
  /// On approve the parent mints a single-use confirmation capability and emits
  /// `approval.resolved` to whoever subscribed — that event is the half of the
  /// dual authority the bridge cannot forge. Returns true when the parent
  /// accepted the resolution.
  @discardableResult
  static func resolve(lease: String, pendingApprovalID: String, approve: Bool) throws -> Bool {
    let result = try DeskPilotPolicySocket.call(
      method: "approval.resolve",
      params: [
        "uiLease": lease,
        "pendingApprovalID": pendingApprovalID,
        "resolution": approve ? "approve" : "deny",
      ])
    return result["resolved"] as? Bool == true
  }
}
