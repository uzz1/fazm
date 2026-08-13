/**
 * Per-query handler for the DeskPilot offline route.
 *
 * In offline mode Hermes is the only ACP agent process, so every turn lands
 * here regardless of the model id Swift reports (see `selectSessionProvider`).
 * The shape mirrors gemini-query.ts / codex-query.ts so all three ACP-shaped
 * backends share session lifecycle, resume, outbound translation, and interrupt
 * semantics — the difference is what sits behind the socket, not how the bridge
 * talks to it.
 *
 * Two things are deliberately unlike the hosted paths:
 *
 *   - No MCP servers are passed. `GenericACPProvider.newSession/loadSession`
 *     send `mcpServers: []` unconditionally, because anything registered here
 *     would be a second execution path the DeskPilot policy gate never sees.
 *
 *   - Inbound `session/request_permission` is answered fail-closed. The policy
 *     gate's user-facing approval lives on the parent socket (Hermes' policy
 *     server) and, later, in the DeskPilot Swift UI; this bridge has no
 *     approval surface of its own, so it denies immediately rather than either
 *     rubber-stamping the request or letting the turn hang until the handle
 *     expires. See `onPermission` inside handleHermesQuery. This is the seam
 *     the DeskPilot approval UI replaces in Tasks 13-15.
 */

import type { OutboundMessage, PriorContextEntry, QueryMessage } from "./protocol.js";
import type { ACPRoute } from "./hermes-route.js";
import type { PermissionHandle } from "./stdio-provider.js";
import { translateCodexUpdate, type TranslatorState } from "./acp-translate.js";

/**
 * The slice of GenericACPProvider hermes-query depends on. Narrowing it keeps
 * the handler unit-testable against a fake child-free provider, and makes a
 * drift in the provider's surface a compile error here.
 */
export interface HermesProviderLike {
  start(): void;
  initialize(): Promise<unknown>;
  newSession(cwd: string): Promise<unknown>;
  loadSession(sessionId: string, cwd: string): Promise<unknown>;
  prompt(sessionId: string, prompt: unknown): Promise<unknown>;
  cancel(sessionId: string): void;
  permission(handle: PermissionHandle, outcome: unknown): void;
  /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
  on(event: string, listener: (...args: any[]) => void): unknown;
  /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
  off(event: string, listener: (...args: any[]) => void): unknown;
}

/** The slice of HermesRouteStore hermes-query depends on. */
export interface HermesRouteLike {
  get(key: string): Readonly<ACPRoute & { generation: number }> | undefined;
  commit(route: ACPRoute, expectedGeneration: number): Promise<Readonly<{ generation: number }>>;
  markPromptUnknown(key: string, expectedSessionID: string): Promise<void>;
}

export interface HermesQueryDeps {
  logErr: (msg: string) => void;
  send: (msg: OutboundMessage) => void;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
  getProvider: () => HermesProviderLike;
  routes: HermesRouteLike;
  registerSession: (
    sessionKey: string,
    entry: { sessionId: string; cwd: string; model?: string; provider: "hermes" },
  ) => void;
}

interface HermesSessionEntry {
  sessionId: string;
  cwd: string;
  systemPromptDelivered: boolean;
}

const hermesSessions = new Map<string, HermesSessionEntry>();
const hermesSessionIdToKey = new Map<string, string>();
/** Providers already handshaked. `initialize` is a per-process handshake, not a
 *  per-turn one; re-sending it every query would burn a round trip on the
 *  visible turn for no gain. */
const initializedProviders = new WeakSet<object>();

function buildPreamble(
  systemPrompt: string | undefined,
  priorContext: PriorContextEntry[] | undefined,
): string | null {
  const parts: string[] = [];
  const trimmed = systemPrompt?.trim();
  if (trimmed) parts.push(`<system_instructions>\n${trimmed}\n</system_instructions>`);
  if (priorContext && priorContext.length > 0) {
    const transcript = priorContext.map((entry) => `[${entry.role}]: ${entry.text}`).join("\n\n");
    parts.push(
      `<conversation_history>\nThe following turns happened previously in this conversation. Use them as context but do not repeat their content.\n\n${transcript}\n</conversation_history>`,
    );
  }
  return parts.length > 0 ? parts.join("\n\n") : null;
}

/**
 * A cancelled turn is a normal ending, not a failure: the user pressed stop and
 * the text produced up to that point is still theirs. Distinguishing it here is
 * what keeps an interrupt from painting a red error in the conversation.
 */
function isCancellation(message: string): boolean {
  return /cancel/i.test(message);
}

export async function handleHermesQuery(msg: QueryMessage, deps: HermesQueryDeps): Promise<void> {
  const { logErr, send, sendWithSession, getProvider, routes, registerSession } = deps;
  const sessionKey = msg.sessionKey ?? msg.model ?? "hermes-default";
  const cwd = msg.cwd ?? process.env.HOME ?? process.cwd();

  let provider: HermesProviderLike;
  try {
    provider = getProvider();
    provider.start();
    if (!initializedProviders.has(provider)) {
      await provider.initialize();
      initializedProviders.add(provider);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logErr(`[hermes-query] agent unavailable: ${message}`);
    send({ type: "error", message: `Hermes unavailable: ${message}` });
    return;
  }

  let entry = hermesSessions.get(sessionKey);
  if (entry && entry.cwd !== cwd) {
    logErr(`[hermes-query] dropping cached session for ${sessionKey}: workspace changed ${entry.cwd} -> ${cwd}`);
    dropHermesSession(sessionKey);
    entry = undefined;
  }

  // Generation read and commit must bracket the session call: the store rejects
  // a commit computed against a generation someone else has since advanced.
  let expectedGeneration = routes.get(sessionKey)?.generation ?? 0;
  let resumeAttemptedSessionId: string | undefined;

  if (!entry) {
    const persisted = routes.get(sessionKey);
    const resumeCandidate = msg.resume
      ?? (persisted?.cwd === cwd ? persisted.resumeSessionID : undefined);

    if (resumeCandidate) {
      try {
        await provider.loadSession(resumeCandidate, cwd);
        entry = { sessionId: resumeCandidate, cwd, systemPromptDelivered: true };
        logErr(`[hermes-query] resumed session ${resumeCandidate.slice(0, 8)} for key=${sessionKey}`);
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: true } as OutboundMessage);
      } catch (resumeErr) {
        logErr(`[hermes-query] session/load failed (creating a fresh session): ${resumeErr}`);
        resumeAttemptedSessionId = resumeCandidate;
      }
    }

    if (!entry) {
      try {
        const created = (await provider.newSession(cwd)) as { sessionId: string };
        entry = { sessionId: created.sessionId, cwd, systemPromptDelivered: false };
        logErr(`[hermes-query] new session ${created.sessionId.slice(0, 8)} for key=${sessionKey} cwd=${cwd}`);
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: false } as OutboundMessage);
        if (resumeAttemptedSessionId) {
          sendWithSession(entry.sessionId, {
            type: "session_expired",
            reason: "hermes session/load failed; created fresh session",
            oldSessionId: resumeAttemptedSessionId,
            newSessionId: entry.sessionId,
            contextRestored: !!(msg.priorContext && msg.priorContext.length > 0),
            restoredMessageCount: msg.priorContext?.length ?? 0,
            sessionKey,
          } as OutboundMessage);
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        logErr(`[hermes-query] session/new failed: ${message}`);
        send({ type: "error", message: `Hermes session failed: ${message}` });
        return;
      }
    }

    hermesSessions.set(sessionKey, entry);
    hermesSessionIdToKey.set(entry.sessionId, sessionKey);
    registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: msg.model, provider: "hermes" });

    // Persist only after the agent actually acknowledged the session. A route
    // written before that would point at an id Hermes never created, and the
    // next launch would resume into nothing.
    const route: ACPRoute = { key: sessionKey, providerID: "hermes", cwd, resumeSessionID: entry.sessionId };
    try {
      const stored = await routes.commit(route, expectedGeneration);
      expectedGeneration = stored.generation;
    } catch (commitErr) {
      // A stale generation means another writer owns this key; the turn can
      // still run against the live session, it just isn't the persisted one.
      logErr(`[hermes-query] route commit rejected for key=${sessionKey}: ${commitErr}`);
    }
  }

  const sessionId = entry.sessionId;
  const translator: TranslatorState = {
    sessionId,
    collectedText: "",
    pendingBoundary: false,
    sendWithSession,
  };

  const onNotification = (frame: unknown): void => {
    const rpc = frame as { method?: string; params?: Record<string, unknown> } | undefined;
    if (rpc?.method !== "session/update") return;
    if (rpc.params?.sessionId !== sessionId) return;
    translateCodexUpdate(rpc.params, translator);
  };

  /**
   * Fail closed. The bridge cannot approve on the user's behalf: the approval
   * that matters is the parent-socket one Hermes' policy gate waits on, and
   * DeskPilot's own approval UI does not exist in this process. Answering
   * `cancelled` immediately keeps the contract (every request gets exactly one
   * reply) without inventing consent, and without a multi-minute stall while
   * the provider's expiry timer runs down.
   */
  const onPermission = (event: unknown): void => {
    const handle = (event as { handle?: PermissionHandle } | undefined)?.handle;
    if (!handle || handle.sessionId !== sessionId) return;
    try {
      provider.permission(handle, { outcome: "cancelled" });
      logErr(`[hermes-query] denied permission ${handle.permissionRequestID} (no approval surface in the bridge)`);
    } catch (err) {
      logErr(`[hermes-query] permission reply failed for ${handle.permissionRequestID}: ${err}`);
    }
  };

  provider.on("notification", onNotification);
  provider.on("permission", onPermission);

  const promptBlocks: Array<Record<string, unknown>> = [];
  if (!entry.systemPromptDelivered) {
    const preamble = buildPreamble(msg.systemPrompt, resumeAttemptedSessionId ? msg.priorContext : undefined);
    if (preamble) promptBlocks.push({ type: "text", text: preamble });
    entry.systemPromptDelivered = true;
  }
  promptBlocks.push({ type: "text", text: msg.prompt });

  try {
    const promptResult = (await provider.prompt(sessionId, promptBlocks)) as {
      stopReason?: string;
      usage?: { inputTokens?: number; outputTokens?: number } | null;
    };
    sendWithSession(sessionId, {
      type: "result",
      text: translator.collectedText,
      sessionId,
      model: msg.model,
      costUsd: 0,
      inputTokens: promptResult?.usage?.inputTokens ?? 0,
      outputTokens: promptResult?.usage?.outputTokens ?? 0,
    });
    logErr(`[hermes-query] turn done session=${sessionId.slice(0, 8)} stop=${promptResult?.stopReason ?? "?"} chars=${translator.collectedText.length}`);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (isCancellation(message)) {
      logErr(`[hermes-query] turn cancelled session=${sessionId.slice(0, 8)} chars=${translator.collectedText.length}`);
      sendWithSession(sessionId, {
        type: "result",
        text: translator.collectedText,
        sessionId,
        model: msg.model,
        costUsd: 0,
      });
    } else {
      logErr(`[hermes-query] session/prompt failed: ${message}`);
      send({ type: "error", message: `Hermes prompt failed: ${message}`, sessionId });
    }
  } finally {
    provider.off("notification", onNotification);
    provider.off("permission", onPermission);
  }
}

/**
 * Mark every route whose prompt completion is unknown after a transport loss.
 * The store's `promptState` is what stops a later resume from silently
 * re-sending a prompt whose side effects may already have happened — which,
 * for a desktop agent, is the difference between one email and two.
 */
export function attachHermesDisconnectRecovery(
  provider: HermesProviderLike,
  routes: HermesRouteLike,
  logErr: (msg: string) => void,
): void {
  provider.on("disconnect", (event: { unknownPromptSessions?: string[] }) => {
    for (const sid of event?.unknownPromptSessions ?? []) {
      const key = hermesSessionIdToKey.get(sid);
      if (!key) continue;
      routes.markPromptUnknown(key, sid).catch((err) => {
        logErr(`[hermes-query] markPromptUnknown failed for key=${key}: ${err}`);
      });
    }
  });
}

export function dropHermesSession(sessionKey: string): void {
  const entry = hermesSessions.get(sessionKey);
  if (!entry) return;
  hermesSessions.delete(sessionKey);
  hermesSessionIdToKey.delete(entry.sessionId);
}

/**
 * Cancel the live turn on one session. Unlike the codex/gemini equivalents the
 * cached entry is kept: ACP `session/cancel` ends the turn, not the session, so
 * the next prompt continues the same conversation rather than starting over.
 */
export function interruptHermesSession(sessionKey: string, provider: HermesProviderLike): boolean {
  const entry = hermesSessions.get(sessionKey);
  if (!entry) return false;
  try {
    provider.cancel(entry.sessionId);
  } catch {
    /* provider already gone */
  }
  return true;
}

export function interruptAllHermesSessions(provider: HermesProviderLike): number {
  let count = 0;
  for (const key of [...hermesSessions.keys()]) {
    if (interruptHermesSession(key, provider)) count += 1;
  }
  return count;
}

export function hermesSessionCount(): number {
  return hermesSessions.size;
}

export function clearHermesSessions(): void {
  hermesSessions.clear();
  hermesSessionIdToKey.clear();
}
