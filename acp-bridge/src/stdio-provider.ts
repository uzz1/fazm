import { EventEmitter } from "node:events";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";

export interface StdioProviderConfig {
  id: "hermes";
  command: string;
  args: readonly string[];
  env: Readonly<Record<string, string>>;
  cwd?: string;
}

type RPC = { jsonrpc: "2.0"; id?: number; method?: string; params?: unknown; result?: unknown; error?: unknown };
type Pending = { generation: number; kind: "control"|"prompt"; sessionId?: string;
  resolve: (value: unknown) => void; reject: (error: Error) => void;
  timer?: NodeJS.Timeout; cancelTimer?: NodeJS.Timeout };
export type PermissionHandle = { rpcID: number; generation: number; sessionId: string; permissionRequestID: string };

type SpawnChild = (...args: Parameters<typeof spawn>) => ChildProcessWithoutNullStreams;

export class GenericACPProvider extends EventEmitter {
  private child: ChildProcessWithoutNullStreams | null = null;
  private lines: ReturnType<typeof createInterface> | null = null;
  private generation = 0;
  private nextID = 1;
  private pending = new Map<number, Pending>();
  private inboundPermissions = new Map<string, { handle: PermissionHandle; timer: NodeJS.Timeout }>();
  private unknownPromptSessions = new Set<string>();
  private shuttingDown = false;
  private reconnecting = false;
  private terminalDisconnectEmitted = false;
  private suppressedDisconnectGenerations = new Set<number>();

  constructor(readonly config: StdioProviderConfig, private readonly controlTimeoutMs = 5_000,
              private readonly cancelAckTimeoutMs = 2_000,
              private readonly permissionGraceMs = 2_000,
              private readonly spawnChild: SpawnChild = spawn as unknown as SpawnChild,
              private readonly sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
              private readonly now = () => Date.now()) { super(); }

  start(): void {
    if (this.shuttingDown) throw new Error("ACP provider is shut down");
    if (this.child) return;
    if (!this.reconnecting) this.terminalDisconnectEmitted = false;
    const generation = ++this.generation;
    const child = this.spawnChild(this.config.command, [...this.config.args], {
      cwd: this.config.cwd, env: { ...process.env, ...this.config.env }, stdio: "pipe",
    });
    this.child = child;
    const lines = createInterface({ input: child.stdout }); this.lines = lines;
    lines.on("line", (line) => this.receive(line, generation));
    child.stderr.on("data", (chunk) => this.emit("stderr", chunk.toString()));
    child.once("exit", () => {
      if (this.child === child) this.child = null;
      lines.close(); if (this.lines === lines) this.lines = null;
      for (const [id, item] of this.pending) {
        if (item.generation !== generation) continue;
        if (item.timer) clearTimeout(item.timer); if (item.cancelTimer) clearTimeout(item.cancelTimer);
        this.pending.delete(id); item.reject(new Error("ACP child exited"));
      }
      for (const [key, item] of this.inboundPermissions) {
        if (item.handle.generation !== generation) continue;
        clearTimeout(item.timer); this.inboundPermissions.delete(key);
        this.emit("permissionCancelled", { ...item.handle, reason: "transport_lost" });
      }
      const suppressed = this.suppressedDisconnectGenerations.delete(generation);
      if (!this.shuttingDown && !this.reconnecting && !suppressed)
        this.emit("disconnect", { terminal: false, unknownPromptSessions: [...this.unknownPromptSessions] });
    });
  }

  initialize() { return this.request("initialize", { protocolVersion: 1, clientInfo: { name: "DeskPilot", version: "1" } }); }
  newSession(cwd: string) { return this.request("session/new", { cwd, mcpServers: [] }); }
  loadSession(sessionId: string, cwd: string) { return this.request("session/load", { sessionId, cwd, mcpServers: [] }); }
  prompt(sessionId: string, prompt: unknown) {
    if (!this.child) throw new Error("ACP child is not running");
    this.unknownPromptSessions.add(sessionId);
    return this.request("session/prompt", { sessionId, prompt }, "prompt", sessionId);
  }
  cancel(sessionId: string): void {
    this.notify("session/cancel", { sessionId });
    const active = [...this.pending.entries()].find(([, item]) => item.kind === "prompt" && item.sessionId === sessionId);
    if (!active) return;
    const [id, item] = active;
    item.cancelTimer = setTimeout(() => {
      if (!this.pending.has(id)) return;
      this.child?.kill("SIGTERM");
    }, this.cancelAckTimeoutMs);
  }
  permission(expected: PermissionHandle, outcome: unknown) {
    const key = this.permissionKey(expected.generation, expected.rpcID);
    const item = this.inboundPermissions.get(key);
    if (!item) throw new Error("ACP permission is absent or expired");
    if (expected.generation !== this.generation) throw new Error("stale ACP permission generation");
    const actual = item.handle;
    if (actual.generation !== expected.generation || actual.sessionId !== expected.sessionId ||
        actual.permissionRequestID !== expected.permissionRequestID)
      throw new Error("stale or mismatched ACP permission handle");
    clearTimeout(item.timer); this.inboundPermissions.delete(key);
    this.write({ jsonrpc: "2.0", id: expected.rpcID, result: { outcome } });
  }

  shutdown(): void {
    this.shuttingDown = true;
    for (const item of this.pending.values()) {
      if (item.timer) clearTimeout(item.timer);
      if (item.cancelTimer) clearTimeout(item.cancelTimer);
      item.reject(new Error("ACP provider shut down"));
    }
    this.pending.clear();
    if (this.child) {
      for (const item of this.inboundPermissions.values()) {
        if (item.handle.generation === this.generation)
          this.write({ jsonrpc: "2.0", id: item.handle.rpcID, result: { outcome: { outcome: "cancelled" } } });
        this.emit("permissionCancelled", { ...item.handle, reason: "shutdown" });
      }
    }
    for (const item of this.inboundPermissions.values()) clearTimeout(item.timer);
    this.inboundPermissions.clear();
    this.lines?.close(); this.lines = null;
    const child = this.child;
    this.child = null;
    child?.kill("SIGTERM");
  }

  async reconnectAndLoad(sessionId: string, cwd: string): Promise<unknown> {
    if (this.shuttingDown) throw new Error("ACP provider is shut down");
    if (this.reconnecting) throw new Error("ACP reconnect already in progress");
    this.reconnecting = true;
    let lastError: unknown = new Error("ACP reconnect exhausted");
    try {
      for (const delay of [250, 500, 1_000, 2_000, 4_000]) {
        await this.sleep(delay);
        if (this.shuttingDown) throw new Error("ACP provider is shut down");
        try {
          this.start(); await this.initialize();
          const restored = await this.loadSession(sessionId, cwd);
          this.terminalDisconnectEmitted = false;
          return restored;
        } catch (error) {
          lastError = error;
          const failed = this.child;
          if (failed) this.suppressedDisconnectGenerations.add(this.generation);
          this.child = null; failed?.kill("SIGTERM");
        }
      }
      if (!this.terminalDisconnectEmitted) {
        this.terminalDisconnectEmitted = true;
        this.emit("disconnect", { terminal: true, unknownPromptSessions: [...this.unknownPromptSessions] });
      }
      throw lastError;
    } finally {
      this.reconnecting = false;
    }
  }

  canResendPrompt(sessionId: string): boolean { return !this.unknownPromptSessions.has(sessionId); }

  private request(method: string, params: unknown, kind: "control"|"prompt" = "control", sessionId?: string): Promise<unknown> {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const deadline = kind === "prompt" ? undefined : this.controlTimeoutMs;
      const timer = deadline === undefined ? undefined : setTimeout(() => {
        this.pending.delete(id); reject(new Error(`ACP timeout: ${method}`));
      }, deadline);
      this.pending.set(id, { generation: this.generation, kind, sessionId, resolve, reject, timer });
      try { this.write({ jsonrpc: "2.0", id, method, params }); }
      catch (error) {
        if (timer) clearTimeout(timer); this.pending.delete(id);
        if (kind === "prompt" && sessionId) this.unknownPromptSessions.delete(sessionId);
        reject(error as Error);
      }
    });
  }

  private notify(method: string, params: unknown): void { this.write({ jsonrpc: "2.0", method, params }); }
  private write(frame: RPC): void {
    if (!this.child) throw new Error("ACP child is not running");
    this.child.stdin.write(JSON.stringify(frame) + "\n");
  }
  private permissionKey(generation: number, rpcID: number): string { return `${generation}:${rpcID}`; }
  private settle(id: number, item: Pending, value: unknown, error?: Error): void {
    if (item.timer) clearTimeout(item.timer); if (item.cancelTimer) clearTimeout(item.cancelTimer);
    this.pending.delete(id);
    if (item.kind === "prompt" && item.sessionId) this.unknownPromptSessions.delete(item.sessionId);
    error ? item.reject(error) : item.resolve(value);
  }
  private receive(line: string, generation: number): void {
    if (generation !== this.generation) return;
    let frame: RPC;
    try { frame = JSON.parse(line) as RPC; } catch { this.emit("protocolError", new Error("malformed ACP JSON")); return; }
    if (frame.id !== undefined && (frame.result !== undefined || frame.error !== undefined)) {
      const item = this.pending.get(frame.id);
      if (!item) return;
      this.settle(frame.id, item, frame.result,
        frame.error === undefined ? undefined : new Error(JSON.stringify(frame.error)));
      return;
    }
    if (frame.method === "session/request_permission" && frame.id !== undefined) {
      const params = frame.params as { sessionId?: string; _meta?: { deskpilot?: { expiresAt?: string; permissionRequestID?: string } } } | undefined;
      const sessionId = params?.sessionId;
      const permissionRequestID = params?._meta?.deskpilot?.permissionRequestID;
      const rpcID = frame.id;
      if (!sessionId || !permissionRequestID) {
        this.write({ jsonrpc: "2.0", id: rpcID, result: { outcome: { outcome: "cancelled" } } });
        this.emit("protocolError", new Error("uncorrelated ACP permission request")); return;
      }
      const handle: PermissionHandle = { rpcID, generation, sessionId, permissionRequestID };
      const permissionKey = this.permissionKey(generation, rpcID);
      const supplied = Date.parse(params?._meta?.deskpilot?.expiresAt ?? "");
      const maximum = this.now() + 300_000;
      const expiresAt = Number.isFinite(supplied) ? Math.min(supplied, maximum) : maximum;
      const timer = setTimeout(() => {
        if (!this.inboundPermissions.delete(permissionKey)) return;
        if (this.child && handle.generation === this.generation)
          this.write({ jsonrpc: "2.0", id: rpcID, result: { outcome: { outcome: "cancelled" } } });
        this.emit("permissionExpired", handle);
      }, Math.max(0, expiresAt - this.now()) + this.permissionGraceMs);
      this.inboundPermissions.set(permissionKey, { handle, timer });
      this.emit("permission", { frame, handle });
    } else if (frame.method) {
      const params = frame.params as { sessionId?: string; update?: { sessionUpdate?: string; type?: string } } | undefined;
      const terminalCancel = frame.method === "session/update" &&
        (params?.update?.sessionUpdate === "cancelled" || params?.update?.type === "cancelled");
      if (terminalCancel && params?.sessionId) {
        for (const [id, item] of this.pending) {
          if (item.kind === "prompt" && item.sessionId === params.sessionId) {
            this.settle(id, item, undefined, new Error("ACP prompt cancelled")); break;
          }
        }
        for (const [key, item] of this.inboundPermissions) {
          if (item.handle.generation === generation && item.handle.sessionId === params.sessionId) {
            clearTimeout(item.timer); this.inboundPermissions.delete(key);
            if (this.child) this.write({ jsonrpc: "2.0", id: item.handle.rpcID, result: { outcome: { outcome: "cancelled" } } });
            this.emit("permissionCancelled", { ...item.handle, reason: "session_cancelled" });
          }
        }
      }
      this.emit("notification", frame);
    }
  }
}

export function hermesConfig(environment: NodeJS.ProcessEnv = process.env): StdioProviderConfig {
  const command = environment.DESKPILOT_HERMES_PYTHON;
  const home = environment.HERMES_HOME;
  const socket = environment.DESKPILOT_POLICY_SOCKET;
  const status = environment.DESKPILOT_STATUS_SOCKET;
  const key = environment.LM_API_KEY;
  if (environment.DESKPILOT_OFFLINE !== "1" || !command?.startsWith("/") || !home?.startsWith("/") ||
      !socket?.startsWith("/") || !status?.startsWith("/") || !key)
    throw new Error("DeskPilot Hermes environment is incomplete");
  return { id: "hermes", command, args: ["-m", "acp_adapter"],
    env: { HERMES_HOME: home, DESKPILOT_MODE: "1", DESKPILOT_OFFLINE: "1",
      DESKPILOT_POLICY_SOCKET: socket, DESKPILOT_STATUS_SOCKET: status, LM_API_KEY: key } };
}
