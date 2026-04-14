# Deks v0.2.0

Deks is a fast macOS workspace manager that switches complete window-level contexts instantly.

## Downloads

- Deks-v0.2.0.zip (unsigned)

## Important: Unsigned Build

This release is unsigned and not notarized because it is distributed without a paid Apple Developer account.

macOS may show a warning on first launch. This is expected.

## First Launch (macOS)

1. Move Deks.app to Applications.
2. Right-click Deks.app and select Open.
3. Click Open in the warning dialog.
4. If still blocked: System Settings > Privacy & Security > Open Anyway.

Optional terminal fallback for advanced users:

```bash
xattr -dr com.apple.quarantine /Applications/Deks.app
```

## Required Permission

Deks needs Accessibility permission to manage windows:

- System Settings > Privacy & Security > Accessibility
- Enable Deks
- After enabling permission, open the Deks popup/settings and reorganize windows into the intended workspaces once.

## What's New in v0.2.0

- ⌘Tab-style hold-to-cycle Quick Switcher: ⌥Tab cycles forward, ⌥⇧Tab cycles backward, release ⌥ commits, Esc cancels. Opening forward pre-selects the previous workspace for flip-flop jumps.
- Send the focused window to workspace N via ⌃⇧1–⌃⇧9.
- Settings drag-and-drop now live-previews window visibility on screen as you rearrange assignments.
- Z-order preservation across workspace switches is now far more reliable thanks to a CG window ID bridge and cross-app back-to-front restore.
- Install script resets Accessibility TCC permission by default on ad-hoc signed builds so every reinstall gets a fresh prompt.
- Test suite expanded from 3 to 79 tests.

Carried over from v0.1.0:

- Window-level workspace management (not just apps — individual windows)
- Instant hotkey switching (Ctrl+1 through Ctrl+9)
- Menu bar widget with search and workspace dropdown
- Idle optimization freezes background workspaces to save RAM
- Named and colored workspaces
- Floating (pinned) windows across all workspaces
- Native HUD overlay on workspace switch
- Launch on login support
- Fully local — no analytics, no network requests

## Known Limitations

- Unsigned build requires manual trust on first launch
- Some apps (Spotify) are single-instance and cannot be split across workspaces
- Accessibility permission may need re-toggle after updates

## Checks

- Built with `swift build -c release`
- Tested on macOS 13+ (Ventura and later)

## Source

https://github.com/NPX2218/deks
