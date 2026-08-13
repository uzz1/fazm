/**
 * The DeskPilot offline branch.
 *
 * In offline mode Hermes is the only ACP agent process, and it owns BrowserOS,
 * cua-driver, Hammerspoon, terminal, and file tools behind the policy gate.
 * Everything Fazm would otherwise bundle — the Playwright extension flow,
 * mcp-server-macos-use, hosted-provider MCPs, and the Fazm tool relay — is a
 * second execution path that policy does not see, so none of it is registered.
 */

import { hermesConfig, type StdioProviderConfig } from "./stdio-provider.js";

type Environment = Record<string, string | undefined>;

export function deskpilotOffline(environment: Environment = process.env): boolean {
  return environment.DESKPILOT_OFFLINE === "1";
}

/**
 * The MCP server set for an offline session: empty, deliberately.
 *
 * Returning a value rather than skipping at the call site keeps the decision in
 * one reviewable place instead of spread across the six buildMcpServers callers.
 */
export function offlineMcpServers(): [] {
  return [];
}

/**
 * The sole provider config for an offline session.
 *
 * hermesConfig validates that offline mode is actually on and that every path
 * is absolute, so a partially configured environment throws here instead of
 * quietly degrading to a hosted provider.
 */
export function offlineProviderConfig(
  environment: Environment = process.env,
): StdioProviderConfig {
  return hermesConfig(environment as NodeJS.ProcessEnv);
}
