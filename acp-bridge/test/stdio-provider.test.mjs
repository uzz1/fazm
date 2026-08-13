import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";

import { GenericACPProvider, hermesConfig } from "../dist/stdio-provider.js";

class FakeChild extends EventEmitter {
  stdin = new PassThrough(); stdout = new PassThrough(); stderr = new PassThrough();
  kill() { this.emit("exit", 0); return true; }
}

// Reads every frame the provider writes. A discrete once(stdin, "data") per step
// cannot be used: stdin buffers whatever was written while no listener was
// attached, so a later await would pick up an earlier step's frame.
function frameReader(child) {
  const pending = [];
  const waiters = [];
  const flush = () => {
    for (let index = 0; index < waiters.length; ) {
      const found = pending.findIndex(waiters[index].match);
      if (found === -1) { index++; continue; }
      waiters.splice(index, 1)[0].resolve(pending.splice(found, 1)[0]);
    }
  };
  child.stdin.on("data", (chunk) => {
    for (const line of chunk.toString().split("\n")) {
      if (line.trim()) pending.push(JSON.parse(line));
    }
    flush();
  });
  return (match) => {
    const found = pending.findIndex(match);
    if (found !== -1) return Promise.resolve(pending.splice(found, 1)[0]);
    return new Promise((resolve) => waiters.push({ match, resolve }));
  };
}

test("stdio provider initializes streams and isolates stderr", async () => {
  const child = new FakeChild();
  const provider = new GenericACPProvider({ id: "hermes", command: "/usr/bin/python3",
    args: ["-m", "acp_adapter"], env: { HERMES_HOME: "/tmp/hermes", DESKPILOT_MODE: "1",
    DESKPILOT_POLICY_SOCKET: "/tmp/policy.sock" } }, 100, 50, 10, () => child);
  provider.start();
  const requestLine = once(child.stdin, "data");
  const pending = provider.initialize();
  const request = JSON.parse((await requestLine)[0].toString());
  assert.equal(request.method, "initialize");
  child.stderr.write("diagnostic only");
  child.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { protocolVersion: 1 } }) + "\n");
  assert.deepEqual(await pending, { protocolVersion: 1 });
  provider.shutdown();
});

test("malformed JSON and timeout fail closed", async () => {
  const child = new FakeChild();
  const provider = new GenericACPProvider({ id: "hermes", command: "/usr/bin/python3", args: [], env: {} },
    5, 5, 5, () => child);
  provider.start();
  const protocolError = once(provider, "protocolError");
  child.stdout.write("not-json\n");
  await protocolError;
  await assert.rejects(provider.newSession("/tmp/project"), /ACP timeout/);
  provider.shutdown();
});

test("prompt, cancellation, and inbound permission use independent lifecycles", async () => {
  const child = new FakeChild();
  const provider = new GenericACPProvider({ id: "hermes", command: "/usr/bin/python3", args: [], env: {} },
    5, 20, 5, () => child);
  provider.start();
  const nextFrame = frameReader(child);
  const isPrompt = (frame) => frame.method === "session/prompt";
  const prompt = provider.prompt("session-a", [{ type: "text", text: "hello" }]);
  await nextFrame(isPrompt);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(provider.canResendPrompt("session-a"), false); // prompt has no control timer
  child.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "session/update",
    params: { sessionId: "session-a", update: { type: "agent_message_chunk" } } }) + "\n");
  const permission = once(provider, "permission");
  child.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 91, method: "session/request_permission",
    params: { sessionId: "session-a", _meta: { deskpilot: { permissionRequestID: "permission-a",
      expiresAt: new Date(Date.now() + 100).toISOString() } } } }) + "\n");
  const [permissionEvent] = await permission;
  provider.permission(permissionEvent.handle, { outcome: "selected", optionId: "allow_once" });
  provider.cancel("session-a");
  child.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "session/update",
    params: { sessionId: "session-a", update: { type: "cancelled" } } }) + "\n");
  await assert.rejects(prompt, /cancelled/); // terminal update is the final frame
  assert.equal(provider.canResendPrompt("session-a"), true);
  const retry = provider.prompt("session-a", [{ type: "text", text: "retry" }]);
  const retryRequest = await nextFrame(isPrompt);
  child.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: retryRequest.id,
    error: { code: -32000, message: "known failure" } }) + "\n");
  await assert.rejects(retry, /known failure/);
  assert.equal(provider.canResendPrompt("session-a"), true);
  provider.shutdown();
});

test("Hermes config is exact and complete", () => {
  assert.deepEqual(hermesConfig({ DESKPILOT_HERMES_PYTHON: "/opt/hermes/python",
    HERMES_HOME: "/Users/test/.deskpilot/hermes", DESKPILOT_OFFLINE: "1",
    DESKPILOT_POLICY_SOCKET: "/tmp/policy.sock", DESKPILOT_STATUS_SOCKET: "/tmp/status.sock",
    LM_API_KEY: "fixture-token" }), {
    id: "hermes", command: "/opt/hermes/python", args: ["-m", "acp_adapter"],
    env: { HERMES_HOME: "/Users/test/.deskpilot/hermes", DESKPILOT_MODE: "1", DESKPILOT_OFFLINE: "1",
      DESKPILOT_POLICY_SOCKET: "/tmp/policy.sock", DESKPILOT_STATUS_SOCKET: "/tmp/status.sock",
      LM_API_KEY: "fixture-token" },
  });
});
