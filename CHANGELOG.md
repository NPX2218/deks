# Changelog

All notable changes to Deks will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
