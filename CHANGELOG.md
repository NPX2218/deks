# Changelog

All notable changes to Deks will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-04-14

### Added
- ⌘Tab-style hold-to-cycle Quick Switcher: ⌥Tab cycles forward, ⌥⇧Tab cycles backward, release ⌥ commits, Esc cancels. Opening forward pre-selects the previous workspace for flip-flop jumps.
- Send focused window to workspace N via ⌃⇧1–⌃⇧9.
- Settings drag-and-drop now live-previews window visibility on screen as you rearrange assignments.
- Expanded unit test suite from 3 to 79 tests covering model codable round-trips, preferences defaults, quick-switcher cycle math, and workspace mutation semantics.

### Changed
- Z-order preservation now bridges the private `_AXUIElementGetWindow` symbol via `@_silgen_name` (the Yabai/Amethyst/Rectangle pattern) to match AX windows to CG window IDs reliably. Capture splits sessions into reliable vs unreliable pools so tooltip/popup CG entries can no longer cannibalize real windows via PID fallback. Restore performs cross-app back-to-front `NSRunningApplication.activate` after per-app `kAXRaise` so stacks survive switches even across apps.
- `HUDManager` now shares one panel-presentation helper between the workspace HUD and the toggle-feedback HUD.
- `TelemetryManager` caches its `ISO8601DateFormatter` and only appends to existing log files.
- Install script resets Accessibility TCC permission by default on ad-hoc signed builds so every reinstall gets a fresh prompt. Set `DEKS_SIGN_IDENTITY` (or `DEKS_RESET_ACCESSIBILITY=0`) to opt out.

### Removed
- Dead `NewWindowBehavior` preference (no UI, never read). Legacy config files continue to decode — the field is silently ignored.

### Fixed
- Hardened force-unwraps in `Persistence` (Application Support URL) and `WindowTracker` (AXValue type checks) that could crash under edge cases.

### Known limitations
- Cross-app z-order is preserved on restore, but interleaved same-app window stacking is best-effort (reordering one app's window *behind* another requires private SkyLight APIs).

## [0.1.0] - 2026-03-25

### Added
- Window-level workspace management via Accessibility API
- Instant hotkey switching (Ctrl+1 through Ctrl+9, configurable)
- Menu bar widget with workspace dropdown and search
- Quick switcher overlay (Opt+Tab) with workspace filtering
- Idle optimization using SIGSTOP/SIGCONT for background workspaces
- Named and colored workspaces (8 colors)
- Launch on login via SMAppService
- Floating (pinned) windows that persist across all workspace switches
- Native HUD overlay on workspace switch
- Auto-assign new windows to active workspace
- Drag-and-drop window assignment in settings panel
- Z-order preservation across workspace switches
- Reset all data button in settings
- Local-only telemetry logging (no network, no analytics)
- Clean uninstall with permission reset
- JSON-based configuration in ~/Library/Application Support/Deks/
