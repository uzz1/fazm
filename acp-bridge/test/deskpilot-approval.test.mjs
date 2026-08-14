import assert from "node:assert/strict";
import test from "node:test";

import {
  DeskPilotApprovalStore,
  readCorrelation,
} from "../dist/deskpilot-approval.js";

const ROUTE = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const PENDING = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
const SESSION = "sess-1";
const PERMISSION = "0f8fad5b-d9cb-469f-a165-70867728950e";
const EXPIRES = "2026-08-14T12:00:00Z";
const EXPIRES_MS = Date.parse(EXPIRES);

function meta(overrides = {}) {
  return {
    routeID: ROUTE,
    sessionID: SESSION,
    permissionRequestID: PERMISSION,
    pendingApprovalID: PENDING,
    expiresAt: EXPIRES,
    ...overrides,
  };
}

function frame(deskpilot) {
  return { method: "session/request_permission", id: 7, params: { sessionId: SESSION, _meta: { deskpilot } } };
}

const handle = { rpcID: 7, generation: 1, sessionId: SESSION, permissionRequestID: PERMISSION };

function response(overrides = {}) {
  return {
    routeID: ROUTE,
    sessionID: SESSION,
    permissionRequestID: PERMISSION,
    pendingApprovalID: PENDING,
    decision: "allow_once",
    ...overrides,
  };
}

function openStore() {
  const store = new DeskPilotApprovalStore();
  const correlation = readCorrelation(frame(meta()));
  assert.notEqual(correlation, null);
  assert.equal(store.open(correlation, handle), true);
  return store;
}

test("correlation is read only from an exact, fully-typed _meta.deskpilot block", () => {
  assert.deepEqual(readCorrelation(frame(meta())), meta());

  // A missing key, an extra key, or a wrong-typed key is not a correlation.
  for (const key of ["routeID", "sessionID", "permissionRequestID", "pendingApprovalID", "expiresAt"]) {
    const short = meta();
    delete short[key];
    assert.equal(readCorrelation(frame(short)), null, `missing ${key} must not correlate`);
    assert.equal(readCorrelation(frame(meta({ [key]: "" }))), null, `empty ${key} must not correlate`);
    assert.equal(readCorrelation(frame(meta({ [key]: 5 }))), null, `numeric ${key} must not correlate`);
  }
  assert.equal(readCorrelation(frame(meta({ extra: "x" }))), null, "an extra key must not correlate");

  // routeID and pendingApprovalID are parent-minted UUIDs; anything else is forged.
  assert.equal(readCorrelation(frame(meta({ routeID: "not-a-uuid" }))), null);
  assert.equal(readCorrelation(frame(meta({ pendingApprovalID: "../../etc" }))), null);
  assert.equal(readCorrelation(frame(meta({ expiresAt: "whenever" }))), null);

  // No _meta at all, and a non-object _meta, are both uncorrelated.
  assert.equal(readCorrelation({ params: { sessionId: SESSION } }), null);
  assert.equal(readCorrelation({ params: { _meta: { deskpilot: "yes" } } }), null);
  assert.equal(readCorrelation(undefined), null);
});

test("an approval needs all four correlation IDs to match", () => {
  // permissionRequestID is the store's key, so a wrong one cannot name a record
  // at all; the other three are compared against the record it names. Both are
  // denials — the distinction is only which check catches it.
  const expected = {
    routeID: "correlation_mismatch",
    sessionID: "correlation_mismatch",
    pendingApprovalID: "correlation_mismatch",
    permissionRequestID: "unknown_request",
  };
  for (const [key, reason] of Object.entries(expected)) {
    const store = openStore();
    const verdict = store.resolve(response({ [key]: "mismatched-value" }), EXPIRES_MS - 1_000);
    assert.equal(verdict.allowed, false, `${key} mismatch must deny`);
    assert.equal(verdict.reason, reason, `${key} mismatch must be caught as ${reason}`);
  }
});

test("a matching allow_once resolves exactly once, and the replay is denied", () => {
  const store = openStore();
  const first = store.resolve(response(), EXPIRES_MS - 1_000);
  assert.equal(first.allowed, true);
  assert.deepEqual(first.handle, handle);

  const replay = store.resolve(response(), EXPIRES_MS - 1_000);
  assert.equal(replay.allowed, false);
  assert.equal(replay.reason, "unknown_request");
});

test("an expired approval is not an approval", () => {
  const store = openStore();
  const verdict = store.resolve(response(), EXPIRES_MS);
  assert.equal(verdict.allowed, false);
  assert.equal(verdict.reason, "expired");
  // ...and the record is gone, so a later click cannot revive it.
  assert.equal(store.resolve(response(), EXPIRES_MS - 60_000).reason, "unknown_request");
});

test("an explicit deny is honoured and consumes the request", () => {
  const store = openStore();
  const verdict = store.resolve(response({ decision: "deny" }), EXPIRES_MS - 1_000);
  assert.equal(verdict.allowed, false);
  assert.equal(verdict.reason, "denied");
  assert.deepEqual(verdict.handle, handle, "a deny still needs its handle so the ACP request gets its one reply");
});

test("anything that is not exactly allow_once or deny is denied", () => {
  for (const decision of ["allow", "ALLOW_ONCE", "allow_always", "", true, 1, null, undefined]) {
    const store = openStore();
    const verdict = store.resolve(response({ decision }), EXPIRES_MS - 1_000);
    assert.equal(verdict.allowed, false, `decision ${String(decision)} must not allow`);
  }
});

test("a malformed or extra-keyed response is denied without consuming the request", () => {
  const store = openStore();
  assert.equal(store.resolve(response({ scope: "session" }), EXPIRES_MS - 1_000).reason, "malformed");
  assert.equal(store.resolve("allow", EXPIRES_MS - 1_000).reason, "malformed");
  assert.equal(store.resolve(null, EXPIRES_MS - 1_000).reason, "malformed");
  // The genuine reply still works: a malformed frame must not be able to burn
  // the pending request and strand the turn.
  assert.equal(store.resolve(response(), EXPIRES_MS - 1_000).allowed, true);
});

test("an unknown permission request ID is denied", () => {
  const store = new DeskPilotApprovalStore();
  const verdict = store.resolve(response(), EXPIRES_MS - 1_000);
  assert.equal(verdict.allowed, false);
  assert.equal(verdict.reason, "unknown_request");
});

test("a duplicate permissionRequestID is refused rather than overwriting the first", () => {
  const store = openStore();
  const correlation = readCorrelation(frame(meta()));
  assert.equal(store.open(correlation, { ...handle, rpcID: 9 }), false);
  // The original handle is the one that still resolves.
  assert.equal(store.resolve(response(), EXPIRES_MS - 1_000).handle.rpcID, 7);
});

test("cancelling a session drops every pending approval it owns", () => {
  const store = openStore();
  const other = readCorrelation(frame(meta({ sessionID: "sess-2", permissionRequestID: PENDING })));
  store.open(other, { ...handle, sessionId: "sess-2", permissionRequestID: PENDING });

  const dropped = store.cancelSession(SESSION);
  assert.equal(dropped.length, 1);
  assert.equal(dropped[0].handle.sessionId, SESSION);
  assert.equal(store.resolve(response(), EXPIRES_MS - 1_000).reason, "unknown_request");
  // The untouched session is unaffected.
  assert.equal(store.size, 1);
});

test("drain hands back every pending approval so transport loss can deny them all", () => {
  const store = openStore();
  const drained = store.drain();
  assert.equal(drained.length, 1);
  assert.equal(store.size, 0);
  assert.equal(store.resolve(response(), EXPIRES_MS - 1_000).reason, "unknown_request");
});

test("the app-facing request carries correlation and expiry only, never model text", () => {
  const store = openStore();
  const outbound = store.describe(PERMISSION);
  assert.deepEqual(Object.keys(outbound).sort(), [
    "expiresAt",
    "pendingApprovalID",
    "permissionRequestID",
    "routeID",
    "sessionID",
  ]);
  // Nothing derived from the model's tool call — no title, no rawInput, no
  // description. The app reads the action and its inputs from the parent
  // policy server's registry using pendingApprovalID as the key.
  assert.equal(JSON.stringify(outbound).includes("DeskPilot approval required"), false);
});
