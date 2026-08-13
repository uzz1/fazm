import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import {
  attachHermesDisconnectRecovery,
  clearHermesSessions,
  handleHermesQuery,
  hermesSessionCount,
  interruptHermesSession,
} from "../dist/hermes-query.js";

/**
 * Structural stand-in for GenericACPProvider. Only the members hermes-query
 * actually uses are implemented, so a drift in that surface fails here rather
 * than at runtime in the app.
 */
class FakeProvider extends EventEmitter {
  started = 0;
  initialized = 0;
  newSessions = [];
  loads = [];
  prompts = [];
  cancels = [];
  permissions = [];
  nextSessionId = "hermes-session-1";
  loadShouldFail = false;
  promptImpl = null;

  running = false;
  // GenericACPProvider.start() returns early when a child is already live, so
  // the fake counts spawns rather than calls — otherwise this asserts a
  // property the real provider does not have.
  start() { if (this.running) return; this.running = true; this.started += 1; }
  async initialize() { this.initialized += 1; return { protocolVersion: 1 }; }
  async newSession(cwd) { this.newSessions.push(cwd); return { sessionId: this.nextSessionId }; }
  async loadSession(sessionId, cwd) {
    this.loads.push({ sessionId, cwd });
    if (this.loadShouldFail) throw new Error("session/load: no such session");
    return {};
  }
  async prompt(sessionId, prompt) {
    this.prompts.push({ sessionId, prompt });
    if (this.promptImpl) return this.promptImpl(this, sessionId, prompt);
    return { stopReason: "end_turn" };
  }
  cancel(sessionId) { this.cancels.push(sessionId); }
  permission(handle, outcome) { this.permissions.push({ handle, outcome }); }

  update(sessionId, update) {
    this.emit("notification", { jsonrpc: "2.0", method: "session/update", params: { sessionId, update } });
  }
}

/** Same generation-guard contract as HermesRouteStore, without touching disk. */
class FakeRoutes {
  entries = new Map();
  commits = [];
  unknowns = [];

  get(key) { return this.entries.get(key); }
  async commit(route, expectedGeneration) {
    const current = this.entries.get(route.key);
    if ((current?.generation ?? 0) !== expectedGeneration) throw new Error("stale route update");
    const stored = { ...route, generation: expectedGeneration + 1, promptState: "idle" };
    this.entries.set(route.key, stored);
    this.commits.push(stored);
    return stored;
  }
  async markPromptUnknown(key, expectedSessionID) {
    const route = this.entries.get(key);
    if (!route || route.resumeSessionID !== expectedSessionID) throw new Error("stale route update");
    this.entries.set(key, { ...route, promptState: "unknown" });
    this.unknowns.push({ key, expectedSessionID });
  }
}

function harness(provider = new FakeProvider(), routes = new FakeRoutes()) {
  const sent = [];
  const registered = [];
  const logs = [];
  return {
    provider,
    routes,
    sent,
    registered,
    logs,
    deps: {
      logErr: (m) => logs.push(m),
      send: (m) => sent.push(m),
      sendWithSession: (sessionId, m) => sent.push({ ...m, sessionId: m.sessionId ?? sessionId }),
      getProvider: () => provider,
      routes,
      registerSession: (key, entry) => registered.push({ key, entry }),
    },
  };
}

function query(overrides = {}) {
  return {
    type: "query",
    id: "q1",
    prompt: "open zed",
    systemPrompt: "",
    sessionKey: "main",
    cwd: "/tmp/project",
    ...overrides,
  };
}

test.beforeEach(() => clearHermesSessions());

test("an offline query creates a Hermes session, persists its route, and streams the turn", async () => {
  const h = harness();
  h.provider.promptImpl = (provider, sessionId) => {
    provider.update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "opening Zed" } });
    return { stopReason: "end_turn" };
  };

  await handleHermesQuery(query(), h.deps);

  assert.deepEqual(h.provider.newSessions, ["/tmp/project"]);
  assert.equal(h.provider.loads.length, 0);
  assert.equal(h.provider.prompts.length, 1);
  assert.equal(h.provider.prompts[0].sessionId, "hermes-session-1");
  assert.deepEqual(h.provider.prompts[0].prompt, [{ type: "text", text: "open zed" }]);

  // Route persistence: exactly the ACPRoute shape, at generation 1.
  assert.equal(h.routes.commits.length, 1);
  assert.equal(h.routes.commits[0].key, "main");
  assert.equal(h.routes.commits[0].providerID, "hermes");
  assert.equal(h.routes.commits[0].cwd, "/tmp/project");
  assert.equal(h.routes.commits[0].resumeSessionID, "hermes-session-1");
  assert.equal(h.routes.commits[0].generation, 1);

  // The shared session map must know this key belongs to Hermes, not Claude.
  assert.deepEqual(h.registered, [{
    key: "main",
    entry: { sessionId: "hermes-session-1", cwd: "/tmp/project", model: undefined, provider: "hermes" },
  }]);

  const result = h.sent.find((m) => m.type === "result");
  assert.ok(result, "a result must be emitted");
  assert.equal(result.text, "opening Zed");
  assert.equal(result.sessionId, "hermes-session-1");
  assert.ok(h.sent.some((m) => m.type === "text_delta" && m.text === "opening Zed"));
});

test("a second query reuses the live session, re-initializes nothing, and leaks no listener", async () => {
  const h = harness();
  await handleHermesQuery(query(), h.deps);
  await handleHermesQuery(query({ prompt: "and focus it" }), h.deps);

  assert.equal(h.provider.started, 1, "start() is idempotent per provider");
  assert.equal(h.provider.initialized, 1, "initialize() is sent once per provider, not once per turn");
  assert.equal(h.provider.newSessions.length, 1, "the warm session is reused");
  assert.equal(h.provider.prompts.length, 2);

  // Only one route generation bump per new session, not one per prompt.
  assert.equal(h.routes.commits.length, 1);

  // After the turn ends, stray updates must not be translated into deltas.
  const before = h.sent.length;
  h.provider.update("hermes-session-1", { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "late" } });
  assert.equal(h.sent.length, before, "the session/update listener is removed when the turn ends");
});

test("a persisted route resumes the Hermes session instead of creating a new one", async () => {
  const h = harness();
  h.routes.entries.set("main", {
    key: "main", providerID: "hermes", cwd: "/tmp/project",
    resumeSessionID: "hermes-session-restored", generation: 3, promptState: "idle",
  });

  await handleHermesQuery(query(), h.deps);

  assert.deepEqual(h.provider.loads, [{ sessionId: "hermes-session-restored", cwd: "/tmp/project" }]);
  assert.equal(h.provider.newSessions.length, 0);
  assert.equal(h.provider.prompts[0].sessionId, "hermes-session-restored");
  // Commit must be guarded on the generation we actually read.
  assert.equal(h.routes.commits[0].generation, 4);
});

test("a failed resume falls back to a fresh session and reports the expiry", async () => {
  const h = harness();
  h.provider.loadShouldFail = true;
  h.routes.entries.set("main", {
    key: "main", providerID: "hermes", cwd: "/tmp/project",
    resumeSessionID: "hermes-session-gone", generation: 1, promptState: "idle",
  });

  await handleHermesQuery(query(), h.deps);

  assert.equal(h.provider.loads.length, 1);
  assert.deepEqual(h.provider.newSessions, ["/tmp/project"]);
  const expired = h.sent.find((m) => m.type === "session_expired");
  assert.ok(expired, "the user must be told the prior session was lost");
  assert.equal(expired.oldSessionId, "hermes-session-gone");
  assert.equal(expired.newSessionId, "hermes-session-1");
});

test("an inbound permission request is answered fail-closed while the turn is live", async () => {
  const h = harness();
  h.provider.promptImpl = (provider, sessionId) => {
    provider.emit("permission", {
      frame: { jsonrpc: "2.0", id: 91, method: "session/request_permission" },
      handle: { rpcID: 91, generation: 1, sessionId, permissionRequestID: "permission-a" },
    });
    return { stopReason: "end_turn" };
  };

  await handleHermesQuery(query(), h.deps);

  assert.equal(h.provider.permissions.length, 1);
  assert.deepEqual(h.provider.permissions[0].outcome, { outcome: "cancelled" });
  assert.equal(h.provider.permissions[0].handle.permissionRequestID, "permission-a");
});

test("a permission request for another session is not answered by this turn", async () => {
  const h = harness();
  h.provider.promptImpl = (provider) => {
    provider.emit("permission", {
      frame: { jsonrpc: "2.0", id: 92, method: "session/request_permission" },
      handle: { rpcID: 92, generation: 1, sessionId: "some-other-session", permissionRequestID: "permission-b" },
    });
    return { stopReason: "end_turn" };
  };

  await handleHermesQuery(query(), h.deps);

  assert.equal(h.provider.permissions.length, 0);
});

test("interrupt cancels only the named session and keeps its route alive", async () => {
  const h = harness();
  await handleHermesQuery(query(), h.deps);
  await handleHermesQuery(query({ sessionKey: "floating" }), h.deps);

  assert.equal(hermesSessionCount(), 2);
  assert.equal(interruptHermesSession("main", h.provider), true);
  assert.deepEqual(h.provider.cancels, ["hermes-session-1"]);
  // ACP cancel ends the turn, not the session: the next prompt continues here.
  assert.equal(hermesSessionCount(), 2);
  assert.equal(interruptHermesSession("absent", h.provider), false);
});

test("a cancelled prompt returns the text collected so far rather than an error", async () => {
  const h = harness();
  h.provider.promptImpl = (provider, sessionId) => {
    provider.update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "partial" } });
    throw new Error("ACP prompt cancelled");
  };

  await handleHermesQuery(query(), h.deps);

  assert.equal(h.sent.filter((m) => m.type === "error").length, 0);
  const result = h.sent.find((m) => m.type === "result");
  assert.ok(result);
  assert.equal(result.text, "partial");
});

test("a prompt failure surfaces as an error, not a silent empty turn", async () => {
  const h = harness();
  h.provider.promptImpl = () => { throw new Error("policy gate denied"); };

  await handleHermesQuery(query(), h.deps);

  const error = h.sent.find((m) => m.type === "error");
  assert.ok(error);
  assert.match(error.message, /policy gate denied/);
});

test("session/new failure surfaces an error and commits no route", async () => {
  const h = harness();
  h.provider.newSession = async () => { throw new Error("hermes is not running"); };

  await handleHermesQuery(query(), h.deps);

  assert.equal(h.routes.commits.length, 0);
  assert.equal(h.provider.prompts.length, 0);
  assert.ok(h.sent.some((m) => m.type === "error" && /hermes is not running/.test(m.message)));
});

test("a transport disconnect marks the route's prompt completion unknown", async () => {
  const h = harness();
  attachHermesDisconnectRecovery(h.provider, h.routes, h.deps.logErr);
  await handleHermesQuery(query(), h.deps);

  h.provider.emit("disconnect", { terminal: false, unknownPromptSessions: ["hermes-session-1"] });
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(h.routes.unknowns, [{ key: "main", expectedSessionID: "hermes-session-1" }]);
});

test("a changed workspace starts a fresh Hermes session instead of reusing the old cwd", async () => {
  const h = harness();
  await handleHermesQuery(query(), h.deps);
  h.provider.nextSessionId = "hermes-session-2";
  await handleHermesQuery(query({ cwd: "/tmp/other" }), h.deps);

  assert.deepEqual(h.provider.newSessions, ["/tmp/project", "/tmp/other"]);
  assert.equal(h.routes.commits.length, 2);
  assert.equal(h.routes.commits[1].cwd, "/tmp/other");
  assert.equal(h.routes.commits[1].generation, 2);
});
