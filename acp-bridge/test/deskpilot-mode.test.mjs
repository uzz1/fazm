import assert from "node:assert/strict";
import test from "node:test";

import {
  deskpilotOffline,
  offlineMcpServers,
  offlineProviderConfig,
} from "../dist/deskpilot-mode.js";

test("offline mode is opt-in and exact", () => {
  assert.equal(deskpilotOffline({ DESKPILOT_OFFLINE: "1" }), true);
  for (const value of ["0", "", "true", "yes", undefined]) {
    assert.equal(deskpilotOffline({ DESKPILOT_OFFLINE: value }), false);
  }
  assert.equal(deskpilotOffline({}), false);
});

test("offline mode registers no bundled MCP server", () => {
  // Hermes owns BrowserOS, cua-driver, Hammerspoon, terminal, and file tools
  // under policy. Any server registered here would be a second, unpoliced
  // execution path reachable from the same model turn.
  assert.deepEqual(offlineMcpServers(), []);
});

test("offline provider is Hermes alone, with no hosted-provider fallback", () => {
  const config = offlineProviderConfig({
    DESKPILOT_HERMES_PYTHON: "/opt/hermes/python",
    HERMES_HOME: "/Users/test/.deskpilot/hermes",
    DESKPILOT_OFFLINE: "1",
    DESKPILOT_POLICY_SOCKET: "/tmp/policy.sock",
    DESKPILOT_STATUS_SOCKET: "/tmp/status.sock",
    LM_API_KEY: "fixture-token",
  });
  assert.equal(config.id, "hermes");
  assert.deepEqual(config.args, ["-m", "acp_adapter"]);
});

test("offline provider refuses to be built outside offline mode", () => {
  // A half-configured environment must fail loudly rather than silently
  // falling back to a hosted provider, which would defeat offline operation.
  assert.throws(() =>
    offlineProviderConfig({
      DESKPILOT_HERMES_PYTHON: "/opt/hermes/python",
      HERMES_HOME: "/Users/test/.deskpilot/hermes",
      DESKPILOT_OFFLINE: "0",
      DESKPILOT_POLICY_SOCKET: "/tmp/policy.sock",
      DESKPILOT_STATUS_SOCKET: "/tmp/status.sock",
      LM_API_KEY: "fixture-token",
    })
  );
});
