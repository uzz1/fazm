import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { HermesRouteStore } from "../dist/hermes-route.js";

test("route commits atomically and rejects stale updates", async () => {
  const root = await mkdtemp(join(tmpdir(), "deskpilot-route-"));
  const path = join(root, "routes.json");
  const store = new HermesRouteStore(path);
  const first = await store.commit({ key: "conversation-1", providerID: "hermes", cwd: "/tmp/project",
                                     resumeSessionID: "session-1" }, 0);
  assert.equal(first.generation, 1);
  await assert.rejects(store.commit({ key: "conversation-1", providerID: "hermes", cwd: "/tmp/other" }, 0),
                       /stale route/);
  const reloaded = new HermesRouteStore(path);
  await reloaded.load();
  assert.equal(reloaded.get("conversation-1").resumeSessionID, "session-1");
});

test("unknown prompt completion blocks resend and cancellation is session scoped", async () => {
  const root = await mkdtemp(join(tmpdir(), "deskpilot-route-"));
  const store = new HermesRouteStore(join(root, "routes.json"));
  await store.commit({ key: "conversation-1", providerID: "hermes", cwd: "/tmp/project",
                       resumeSessionID: "session-1" }, 0);
  await store.markPromptUnknown("conversation-1", "session-1");
  assert.equal(store.canResendPrompt("conversation-1"), false);
  await assert.rejects(store.markPromptUnknown("conversation-1", "stale-session"), /stale route/);
});
