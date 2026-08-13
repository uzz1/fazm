import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export interface ACPRoute { key: string; providerID: "hermes"; cwd: string; resumeSessionID?: string }
type Stored = ACPRoute & { generation: number; promptState: "idle" | "unknown" };

export class HermesRouteStore {
  private routes = new Map<string, Stored>();
  constructor(private readonly path: string) {}

  async load(): Promise<void> {
    try {
      const value = JSON.parse(await readFile(this.path, "utf8")) as Stored[];
      this.routes = new Map(value.map((route) => [route.key, route]));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  get(key: string): Readonly<Stored> | undefined { return this.routes.get(key); }
  async commit(route: ACPRoute, expectedGeneration: number): Promise<Readonly<Stored>> {
    const current = this.routes.get(route.key);
    if ((current?.generation ?? 0) !== expectedGeneration) throw new Error("stale route update");
    const stored: Stored = { ...route, generation: expectedGeneration + 1, promptState: "idle" };
    this.routes.set(route.key, stored); await this.persist(); return stored;
  }
  async markPromptUnknown(key: string, expectedSessionID: string): Promise<void> {
    const route = this.routes.get(key);
    if (!route || route.resumeSessionID !== expectedSessionID) throw new Error("stale route cancellation");
    this.routes.set(key, { ...route, promptState: "unknown" }); await this.persist();
  }
  canResendPrompt(key: string): boolean { return this.routes.get(key)?.promptState === "idle"; }
  private async persist(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.${process.pid}.tmp`;
    await writeFile(temporary, JSON.stringify([...this.routes.values()]), { mode: 0o600 });
    await rename(temporary, this.path);
  }
}
