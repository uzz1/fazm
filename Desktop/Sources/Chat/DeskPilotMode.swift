import Foundation

/// Whether this build is running as DeskPilot rather than stock Fazm.
///
/// DeskPilot supplies its own model stack — Hermes over ACP against a locally
/// served model — and reaches none of Fazm's hosted infrastructure: the offline
/// branch in `acp-bridge` registers no bundled MCP servers, no hosted provider,
/// and no tool relay. Fazm's subscription gates therefore stand between the user
/// and compute the user already owns, so this build skips them.
///
/// Keyed off the same `deskpilotOfflineEnabled` default that gates the bridge
/// environment (`ACPBridge.deskpilotEnvironment`) and the UI lease
/// (`DeskPilotUILease`), so a stock Fazm build is untouched and the gates return
/// the moment the default is off.
enum DeskPilotMode {
  static var isOffline: Bool {
    UserDefaults.standard.bool(forKey: "deskpilotOfflineEnabled")
  }
}
