import AppKit
import Foundation

/// The human-approval gate for privileged DeskPilot actions.
///
/// ## Why both halves exist
///
/// An `ask` or `local_confirm` action needs two independent approvals, and
/// Hermes (`runtime_context.wait_for_local_approval`) proceeds only when both
/// arrive and agree on every correlation ID:
///
///   1. **The parent policy socket.** `approval.resolve` is lease-gated: the
///      parent takes the PID of its socket peer, resolves that PID's
///      executable, and checks its code-signing identifier against a closed
///      allowlist. Only this process can pass that. Approving mints a
///      single-use confirmation capability and emits `approval.resolved` to the
///      subscriber — which is Hermes, blocked waiting for exactly that frame.
///
///   2. **The ACP outcome**, which travels back through the bridge.
///
/// This type is the only thing that produces (1), and it produces (2) only
/// after (1) succeeded. Neither alone runs anything: a compromised bridge can
/// forge the ACP outcome all day and Hermes will still deny for want of a
/// parent event, and a parent event with no matching ACP outcome denies too.
///
/// ## What the user is shown
///
/// Everything in the dialog comes from `approval.list`, which the parent
/// answers out of the action registry — the same resolution that authorized
/// the action. The model that asked for this action reads untrusted screen
/// text, web pages, and tool output, so its own account of what it is about to
/// do is not evidence. The bridge deliberately forwards no model text at all
/// (see `deskpilot-approval.ts`); `pendingApprovalID` is a lookup key, and the
/// registry answers the question "what will actually happen".
///
/// The one attacker-influenced surface left is the *values* of the action's
/// inputs. Those are registry-validated but still model-chosen, so they are
/// flattened to a single line each, control characters stripped, length
/// capped, and rendered quoted under an explicit heading — a value cannot lay
/// out a line that reads as another field or as a verdict the policy did not
/// reach.
///
/// ## Fail closed
///
/// Denial is the outcome for: no live UI lease; a `pendingApprovalID` the
/// parent is not holding; an item that will not fully parse; an item already
/// past its expiry; an expiry that lapses while the dialog is open; the item
/// changing between being shown and being approved; a refused or failed
/// `approval.resolve`; and a dismissed dialog. The user not answering is not
/// consent — the parent expires the pending approval on its own and the bridge
/// answers the stranded ACP request.
@MainActor
final class DeskPilotApprovalCoordinator {

  static let shared = DeskPilotApprovalCoordinator()

  /// One permission request as the bridge described it: correlation and expiry.
  /// Note what is absent — there is no action name here, because the bridge is
  /// not a trustworthy source for one.
  struct Request: Equatable, Sendable {
    let routeID: String
    let sessionID: String
    let permissionRequestID: String
    let pendingApprovalID: String
    let expiresAt: Date
  }

  /// Sends the ACP half back down the bridge. Set by `ACPBridge`.
  var respond: (@Sendable (Request, Bool) -> Void)?

  /// Requests waiting behind the one on screen. Serialised deliberately: two
  /// consent dialogs at once is how a user approves the wrong one.
  private var queued: [Request] = []
  private var presenting = false
  private var closed = Set<String>()

  private init() {}

  // MARK: - Inbound

  func handle(_ request: Request) {
    guard !closed.contains(request.permissionRequestID) else {
      // The bridge already told us this request died; nothing to consent to.
      closed.remove(request.permissionRequestID)
      deny(request, why: "request already closed")
      return
    }
    queued.append(request)
    drain()
  }

  /// The bridge says this request is gone (expired, cancelled, transport lost).
  /// Drop it so it can never be presented or approved after the fact.
  func close(permissionRequestID: String) {
    queued.removeAll { $0.permissionRequestID == permissionRequestID }
    closed.insert(permissionRequestID)
  }

  // MARK: - Queue

  private func drain() {
    guard !presenting, !queued.isEmpty else { return }
    let request = queued.removeFirst()
    presenting = true
    lookUpThenPresent(request)
  }

  private func finish(_ request: Request, approved: Bool) {
    respond?(request, approved)
    presenting = false
    drain()
  }

  private func deny(_ request: Request, why: String) {
    fputs("[deskpilot] approval denied for \(request.pendingApprovalID): \(why)\n", stderr)
    finish(request, approved: false)
  }

  // MARK: - Look-up

  /// Ask the parent what this pending approval actually is, off the main
  /// thread, then present. A request the parent is not holding is denied
  /// without ever being shown: there would be nothing truthful to show.
  private func lookUpThenPresent(_ request: Request) {
    let pendingID = request.pendingApprovalID
    Task {
      let found = await Task.detached(priority: .userInitiated) {
        Self.lookUp(pendingApprovalID: pendingID)
      }.value

      guard let action = found else {
        deny(request, why: "parent is not holding this pending approval")
        return
      }
      guard action.expiresAt > Date() else {
        deny(request, why: "already expired at look-up")
        return
      }
      guard !closed.contains(request.permissionRequestID) else {
        closed.remove(request.permissionRequestID)
        deny(request, why: "closed while being looked up")
        return
      }
      present(request, action)
    }
  }

  nonisolated private static func lookUp(pendingApprovalID: String) -> DeskPilotPendingAction? {
    guard let lease = DeskPilotUILease.lease() else {
      fputs("[deskpilot] approval: no live UI lease\n", stderr)
      return nil
    }
    do {
      return try DeskPilotApprovalService.find(lease: lease, pendingApprovalID: pendingApprovalID)
    } catch {
      fputs("[deskpilot] approval: look-up failed: \(error)\n", stderr)
      return nil
    }
  }

  // MARK: - Presentation

  private func present(_ request: Request, _ action: DeskPilotPendingAction) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Allow “\(action.actionID)” to run?"
    alert.informativeText = Self.body(for: action, expiresAt: request.expiresAt)

    // Deny is added first, so it is the default and Return cannot approve.
    alert.addButton(withTitle: "Deny")
    alert.addButton(withTitle: "Allow Once")

    NSApp.activate(ignoringOtherApps: true)
    alert.window.level = .modalPanel
    let response = alert.runModal()
    let approved = response == .alertSecondButtonReturn

    guard approved else {
      recordDenial(request)
      return
    }
    confirm(request, action)
  }

  /// The dialog body, assembled entirely from registry and policy fields.
  static func body(for action: DeskPilotPendingAction, expiresAt: Date) -> String {
    var lines: [String] = []
    lines.append("DeskPilot is asking to run a privileged action on this Mac.")
    lines.append("")
    lines.append("Action:   \(action.actionID) (version \(action.actionVersion))")
    lines.append("Risk:     \(action.risk)")
    lines.append("Policy:   \(action.verdict) — \(action.ruleID)")
    lines.append("Reason:   \(action.reason)")
    lines.append("Source:   \(action.entryPoint)\(action.sender.map { " (\($0))" } ?? "")")
    lines.append("")
    if action.displayInputs.isEmpty {
      lines.append("Inputs:   (none)")
    } else {
      lines.append("Inputs, as validated by the action registry:")
      for (key, value) in action.displayInputs {
        lines.append("  • \(key) = \u{201C}\(value)\u{201D}")
      }
    }
    lines.append("")
    lines.append("Trace:    \(action.traceID)")
    lines.append("Digest:   \(action.actionDigest)")
    lines.append("Expires:  \(DeskPilotUILease.rfc3339(expiresAt))")
    lines.append("")
    lines.append(
      "Allowing permits this action once, with exactly these inputs. "
        + "It does not grant anything else, and it cannot be reused.")
    return lines.joined(separator: "\n")
  }

  // MARK: - Resolution

  /// Approve: parent first, then ACP.
  ///
  /// The order is forced by Hermes, which blocks on `approval.subscribe` for
  /// the parent event before it ever reads the ACP outcome. It is also the safe
  /// order: if the parent refuses, nothing has been told "allowed" yet.
  ///
  /// Before resolving, the item is read back and compared field-for-field with
  /// what was on screen. That closes the window between showing and clicking —
  /// if the pending approval is no longer exactly the action whose inputs the
  /// user read, their consent does not apply to it.
  private func confirm(_ request: Request, _ action: DeskPilotPendingAction) {
    Task {
      let outcome = await Task.detached(priority: .userInitiated) {
        Self.resolveApproval(request: request, action: action)
      }.value

      if outcome.approved {
        fputs("[deskpilot] approved \(action.actionID) once (pending \(request.pendingApprovalID))\n", stderr)
        finish(request, approved: true)
      } else {
        deny(request, why: outcome.why)
      }
    }
  }

  nonisolated private static func resolveApproval(
    request: Request, action: DeskPilotPendingAction
  ) -> (approved: Bool, why: String) {
    guard let lease = DeskPilotUILease.lease() else {
      return (false, "no live UI lease at confirmation")
    }
    do {
      guard let fresh = try DeskPilotApprovalService.find(
        lease: lease, pendingApprovalID: request.pendingApprovalID)
      else { return (false, "pending approval vanished before it could be resolved") }

      guard fresh == action else {
        return (false, "pending approval changed between being shown and being approved")
      }
      guard fresh.expiresAt > Date() else {
        return (false, "expired while the dialog was open")
      }
      guard try DeskPilotApprovalService.resolve(
        lease: lease, pendingApprovalID: request.pendingApprovalID, approve: true)
      else { return (false, "parent did not accept the resolution") }

      return (true, "approved")
    } catch {
      return (false, "parent refused or was unreachable: \(error)")
    }
  }

  /// Deny: tell the parent so it resolves and revokes, then tell the bridge.
  /// The ACP denial is sent whether or not the parent call succeeded — a
  /// failure to record the denial must never read as an approval.
  private func recordDenial(_ request: Request) {
    let pendingID = request.pendingApprovalID
    Task {
      await Task.detached(priority: .userInitiated) {
        guard let lease = DeskPilotUILease.lease() else { return }
        _ = try? DeskPilotApprovalService.resolve(
          lease: lease, pendingApprovalID: pendingID, approve: false)
      }.value
      deny(request, why: "denied by the user")
    }
  }
}
