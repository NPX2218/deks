<p align="center">
  <img src="assets/deks-icon-512.png" width="128" height="128" alt="Deks logo">
</p>

<h1 align="center">deks</h1>

<p align="center">
  <strong>The workspace manager macOS deserves.</strong>
</p>

<p align="center">
  Switch between complete working environments — apps, browser windows, tabs — instantly.<br>
  No swipe animations. No clutter. No wasted RAM.
</p>

<p align="center">
  <a href="https://github.com/NPX2218/deks/releases/latest">
    <img src="https://img.shields.io/github/v/release/NPX2218/deks?style=flat-square&color=378ADD&label=latest" alt="Latest Release">
  </a>
  <a href="https://github.com/NPX2218/deks/releases">
    <img src="https://img.shields.io/github/downloads/NPX2218/deks/total?style=flat-square&color=1D9E75&label=downloads" alt="Total Downloads">
  </a>
  <a href="https://github.com/NPX2218/deks/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/NPX2218/deks?style=flat-square&color=7F77DD" alt="License">
  </a>
  <a href="https://github.com/NPX2218/deks/stargazers">
    <img src="https://img.shields.io/github/stars/NPX2218/deks?style=flat-square&color=D85A30" alt="Stars">
  </a>
  <img src="https://img.shields.io/badge/macOS-13.0%2B-888?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9+">
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#installation">Install</a> •
  <a href="#usage">Usage</a> •
  <a href="#permissions">Permissions</a> •
  <a href="#roadmap">Roadmap</a>
</p>

---

<!-- If you have a screenshot or demo GIF, put it here: -->
<!-- <p align="center">
  <img src="assets/deks-demo.gif" width="720" alt="Deks demo">
</p> -->

## The problem

Everyone juggles multiple contexts — school, freelance work, social media, side projects. macOS Spaces is too slow: you can't assign specific browser windows to specific spaces, switching has an animation you can't skip, and idle workspaces still eat your RAM.

Existing tools like FlashSpace work at the **app level**, so "Brave" is either visible or hidden. You can't put one Brave window in your School workspace and another in Social.

Deks works at the **window level**. Three Brave windows can live in three different workspaces.

## Features

### Window-level workspace management
Deks tracks individual windows, not just apps. It scrapes active macOS layers via CoreGraphics to preserve z-order stacking — switch away and switch back, and your windows restore in the exact same front-to-back arrangement.

### Browser tab group awareness
Deks reads Chromium-based browser (Chrome, Brave, Edge, Arc) window titles and tab groups through the Accessibility API. In the config panel you see "Brave — Canvas, Piazza" instead of just "Brave."

### Instant hotkey switching
Each workspace binds to a global hotkey (`⌥1`, `⌥2`, `⌥3`...). No animation, no delay. The switch is immediate.

### HUD overlay
When you switch workspaces, a translucent frosted-glass HUD flashes in the center of your screen — like the macOS volume/brightness indicator — showing the workspace name and color. It fades after one second.

### Auto-assign new windows
Deks continuously monitors for new windows via `AXUIElement` observers. When a new Terminal window or browser tab spawns, it's automatically assigned to your currently active workspace. No manual dragging required.

### Idle optimization
Workspaces inactive for 5 minutes get their exclusive processes frozen via POSIX `SIGSTOP`. This halts CPU execution without killing the app — saving battery and RAM. When you switch back, Deks sends `SIGCONT` and the apps resume instantly.

### Quick switcher
Press `⌥Tab` to open a Spotlight-style overlay. Type to filter workspaces, arrow keys to navigate, Enter to switch.

### Launch on login
Deks registers itself via `SMAppService` so it starts silently in the background every time your Mac boots. No Dock icon, no login item clutter.

## Installation

### Build from source

```bash
git clone https://github.com/NPX2218/deks.git
cd deks
swift run
```

### Generate the .app bundle

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

This compiles an optimized release binary, generates the `Info.plist`, converts the icon to `.icns`, and outputs a `Deks.app` bundle you can drag into `/Applications`.

## Permissions

Deks uses the macOS **Accessibility API** to enumerate windows, read browser tab groups, and manage window visibility. On first launch, macOS will prompt you to grant Accessibility access to your Terminal (or IDE). Grant it and restart the app.

No other permissions are required. Deks doesn't access your files, camera, microphone, or network.

## Usage

1. **Menu bar** — Deks lives in your menu bar. Click the icon for a dropdown of all workspaces.
2. **Settings** — Click "Settings..." to open the config panel. Deks shows all tracked windows; drag them into workspaces on the left.
3. **Customize** — Rename workspaces, pick colors, toggle idle optimization, and set hotkeys per workspace.
4. **Switch** — Hit `⌥1`–`⌥9` to jump between workspaces, or `⌥Tab` for the quick switcher.

## Privacy

All data stays on your machine in `~/Library/Application Support/Deks/`. No analytics, no telemetry, no network requests. Fully open source — read every line.

## Roadmap

- [x] Window-level workspace management with z-order preservation
- [x] Browser tab group awareness (Chromium)
- [x] Global hotkey switching
- [x] Menu bar widget
- [x] Quick switcher overlay
- [x] HUD overlay on switch
- [x] Idle optimization (SIGSTOP/SIGCONT)
- [x] Auto-assign new windows
- [x] Launch on login
- [ ] Workspace snapshots & restore across restarts
- [ ] Workspace-specific wallpapers
- [ ] Focus mode integration
- [ ] Floating windows (persist across all workspaces)
- [ ] Smart rules engine (auto-assign by URL, app, display)
- [ ] Launch sequences (boot all apps for a workspace in one click)
- [ ] Built-in time tracking per workspace
- [ ] Dock morphing per workspace
- [ ] Multi-monitor independence
- [ ] Workspace templates & community sharing
- [ ] Shortcuts / Raycast integration

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)

---

<p align="center">
  <sub><b>deks</b> — your desk, your rules.</sub>
</p>