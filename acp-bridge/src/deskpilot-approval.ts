/**
 * The bridge half of DeskPilot's human-approval path.
 *
 * An `ask` or `local_confirm` action needs two independent approvals before it
 * runs, and Hermes (`runtime_context.wait_for_local_approval`) refuses to
 * proceed without both:
 *
 *   1. the **ACP** `session/request_permission` outcome, which travels back
 *      down this bridge, and
 *   2. the **parent policy socket**'s `approval.resolved` event, which the app
 *      triggers directly by calling `approval.resolve` with its verified UI
 *      lease — a socket this process cannot satisfy, because the parent takes
 *      the peer PID and checks that PID's code signature.
 *
 * That split is the point. This module carries leg 1 only. It cannot mint leg 2
 * and must never be able to: if the bridge were subverted it could reply
 * "allowed" here all day and Hermes would still deny, because no matching
 * parent event exists. Equally, a parent event alone is not enough — Hermes
 * waits on this ACP outcome too.
 *
 * ## What the app is told, and what it is deliberately not told
 *
 * `describe()` returns correlation IDs and an expiry, and nothing else. The
 * inbound `session/request_permission` frame also carries a `title` and a
 * `rawInput` built by Hermes from a model turn, and that model reads untrusted
 * screen text, web pages, and tool output. Forwarding any of it would let the
 * model write the words a human reads before consenting. So the app gets a
 * `pendingApprovalID` and uses it as a lookup key against the parent policy
 * server's `approval.list`, which answers from the action registry: the
 * resolved action ID, its version, its validated inputs, and the policy
 * verdict. The human is shown the registry's account of what will happen, not
 * the model's.
 *
 * ## Fail-closed inventory
 *
 * Every one of these denies, and none of them is recoverable by retrying:
 * an uncorrelated or malformed `_meta.deskpilot`; a response naming an unknown
 * permission request; a response whose routeID, sessionID, or pendingApprovalID
 * disagrees with the record; a response arriving at or after `expiresAt`; a
 * decision that is not exactly `allow_once` or `deny`; a replayed response; a
 * cancelled session; and transport loss (see `drain`). The absence of a
 * response is a denial too — `GenericACPProvider` runs its own expiry timer and
 * answers `cancelled` when it fires.
 */

import type { PermissionHandle } from "./stdio-provider.js";

/** The exact `_meta.deskpilot` block Hermes attaches to a permission request. */
export interface ApprovalCorrelation {
  routeID: string;
  sessionID: string;
  permissionRequestID: string;
  pendingApprovalID: string;
  expiresAt: string;
}

export type DenyReason =
  | "malformed"
  | "unknown_request"
  | "correlation_mismatch"
  | "expired"
  | "denied";

export type ApprovalVerdict =
  | { allowed: true; handle: PermissionHandle }
  | { allowed: false; reason: DenyReason; handle?: PermissionHandle };

interface Record_ {
  correlation: ApprovalCorrelation;
  handle: PermissionHandle;
  expiresAtMs: number;
}

const CORRELATION_KEYS = [
  "routeID",
  "sessionID",
  "permissionRequestID",
  "pendingApprovalID",
  "expiresAt",
] as const;

const RESPONSE_KEYS = [
  "type",
  "routeID",
  "sessionID",
  "permissionRequestID",
  "pendingApprovalID",
  "decision",
] as const;

/** Lowercase canonical UUID. `routeID` and `pendingApprovalID` are minted by
 *  Hermes and the parent respectively; nothing else is a legitimate value. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function exactKeys(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const actual = Object.keys(value as Record<string, unknown>);
  return actual.length === keys.length && keys.every((key) => actual.includes(key));
}

/**
 * Extract the correlation from an inbound `session/request_permission` frame,
 * or null if the frame does not carry an exact, well-typed one. Null means
 * deny: an uncorrelated request can never be matched to a parent approval, so
 * approving it would be approving something unidentifiable.
 */
export function readCorrelation(frame: unknown): ApprovalCorrelation | null {
  const params = (frame as { params?: unknown } | undefined)?.params;
  if (typeof params !== "object" || params === null) return null;
  const meta = (params as { _meta?: unknown })._meta;
  if (typeof meta !== "object" || meta === null) return null;
  const deskpilot = (meta as { deskpilot?: unknown }).deskpilot;
  if (!exactKeys(deskpilot, CORRELATION_KEYS)) return null;

  for (const key of CORRELATION_KEYS) {
    if (!nonEmptyString(deskpilot[key])) return null;
  }
  if (!UUID.test(deskpilot.routeID as string)) return null;
  if (!UUID.test(deskpilot.pendingApprovalID as string)) return null;
  if (!Number.isFinite(Date.parse(deskpilot.expiresAt as string))) return null;

  return {
    routeID: deskpilot.routeID as string,
    sessionID: deskpilot.sessionID as string,
    permissionRequestID: deskpilot.permissionRequestID as string,
    pendingApprovalID: deskpilot.pendingApprovalID as string,
    expiresAt: deskpilot.expiresAt as string,
  };
}

/**
 * The bridge's pending-approval table. One entry per in-flight
 * `session/request_permission`, keyed by the permission request ID Hermes
 * generated. Entries leave the table exactly once — resolved, expired,
 * cancelled, or drained — so no approval can be replayed.
 */
export class DeskPilotApprovalStore {
  private readonly records = new Map<string, Record_>();

  get size(): number {
    return this.records.size;
  }

  /** Register a request. Refuses a duplicate ID rather than overwriting: an
   *  overwrite would strand the first ACP request without a reply, and would
   *  let a second request inherit the first's pending human decision. */
  open(correlation: ApprovalCorrelation, handle: PermissionHandle): boolean {
    const key = correlation.permissionRequestID;
    if (this.records.has(key)) return false;
    if (handle.permissionRequestID !== key || handle.sessionId !== correlation.sessionID) return false;
    this.records.set(key, { correlation, handle, expiresAtMs: Date.parse(correlation.expiresAt) });
    return true;
  }

  /** What the app is allowed to see: correlation and expiry, no model text. */
  describe(permissionRequestID: string): Omit<ApprovalCorrelation, never> | Record<string, never> {
    const record = this.records.get(permissionRequestID);
    if (!record) return {} as Record<string, never>;
    const { routeID, sessionID, pendingApprovalID, expiresAt } = record.correlation;
    return { routeID, sessionID, permissionRequestID, pendingApprovalID, expiresAt };
  }

  /**
   * Apply the app's decision. Consumes the record on every outcome except a
   * malformed frame — a garbled or hostile message must not be able to burn a
   * legitimate pending approval and strand the turn.
   */
  resolve(response: unknown, nowMs: number): ApprovalVerdict {
    if (!exactKeys(response, RESPONSE_KEYS)) return { allowed: false, reason: "malformed" };
    for (const key of RESPONSE_KEYS) {
      if (!nonEmptyString(response[key])) return { allowed: false, reason: "malformed" };
    }
    // The whole wire frame is validated, `type` included, so an extra or
    // renamed field is a rejection rather than something quietly ignored.
    if (response.type !== "deskpilot_permission_response") {
      return { allowed: false, reason: "malformed" };
    }

    const key = response.permissionRequestID as string;
    const record = this.records.get(key);
    if (!record) return { allowed: false, reason: "unknown_request" };

    const { correlation, handle } = record;
    if (
      response.routeID !== correlation.routeID ||
      response.sessionID !== correlation.sessionID ||
      response.pendingApprovalID !== correlation.pendingApprovalID
    ) {
      // The record survives: a mismatched reply is somebody else's, and the
      // real one may still arrive before expiry.
      return { allowed: false, reason: "correlation_mismatch" };
    }

    this.records.delete(key);

    // Expiry is checked after correlation and before the decision, so a stale
    // click cannot be rescued by carrying the right IDs.
    if (nowMs >= record.expiresAtMs) return { allowed: false, reason: "expired", handle };
    if (response.decision !== "allow_once") return { allowed: false, reason: "denied", handle };
    return { allowed: true, handle };
  }

  /** Forget one request without deciding it (its ACP request was answered by
   *  the provider's own expiry timer). */
  forget(permissionRequestID: string): void {
    this.records.delete(permissionRequestID);
  }

  /** Drop every approval belonging to a cancelled session. */
  cancelSession(sessionID: string): Record_[] {
    const dropped: Record_[] = [];
    for (const [key, record] of this.records) {
      if (record.correlation.sessionID !== sessionID) continue;
      this.records.delete(key);
      dropped.push(record);
    }
    return dropped;
  }

  /** Empty the table, handing back what was in it so each can be denied. */
  drain(): Record_[] {
    const all = [...this.records.values()];
    this.records.clear();
    return all;
  }
}

/**
 * The ACP outcome for an approved request.
 *
 * The discriminator is `"selected"`, not `"allowed"` — `acp.schema.AllowedOutcome`
 * declares `outcome: Literal["selected"]`. Sending `"allowed"` produced a
 * response Hermes could not read as an approval, so it denied with "approval
 * capability required" even though the parent had already resolved. That was
 * the dual-authority gate behaving correctly on a bridge that was wrong, which
 * is exactly why the ACP leg is not permitted to be a formality.
 *
 * `allow_once` is the only option DeskPilot offers: there is no allow-always
 * and no session-scoped grant, so no approval can cover an action the user was
 * not shown.
 */
export const ALLOW_ONCE_OUTCOME = { outcome: "selected", optionId: "allow_once" } as const;

/** The ACP outcome for everything else. `acp.schema.DeniedOutcome` is
 *  `outcome: Literal["cancelled"]`. */
export const DENY_OUTCOME = { outcome: "cancelled" } as const;
