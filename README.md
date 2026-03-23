<div align="center">
  <h1>Deks</h1>
  <p><b>The workspace manager macOS deserves.</b></p>
</div>

<p align="center">
  Switch between complete working environments — apps, browser windows, tabs — instantly. No swipe animations, no visual clutter, no wasted RAM.
</p>

---

## 🚀 Features

**Deks is a deeply-native macOS kernel utility that combines window-level workspace management, robust Chrome/Brave tab group awareness, POSIX idle resource optimization, and a polished quick-switching UI.**

- **Z-Order Workspace Preservation** — The engine natively scrapes active physical macOS layers using CoreGraphics to flawlessly preserve vertical stacking. Switch to a new workspace and switch back, and your windows will identically restore themselves exactly layered back-to-front.
- **HUD Target Overlay** — Premium Raycast/macOS Volume style floating translucent frosted-glass HUDs dynamically flash in the center of your screen sequentially rendering color-coded targets whenever you rapidly jump between Workspaces.
- **Instant Hotkey Switching** — Deks instantly binds `⌥1`, `⌥2`, `⌥3` to jump seamlessly across contexts natively globally on the OS.
- **Auto-Assign Background Hooks** — The tracker persistently continuously scrapes `.AXUIElement` frameworks transparently in the background so whenever a completely new, unrecognized Terminal window or Safari tab spawns, it merges seamlessly into your currently active environment automatically without any prompt UI.
- **RAM Optimization (SIGSTOP Engine)** — Completely freeze idle applications natively! If a workspace with memory-heaving clients (like heavy browser windows) hasn't been accessed in precisely 5 minutes, Deks silently invokes a POSIX `SIGSTOP` signal halting process execution explicitly without crashing it, saving battery and RAM instantly until you flip back.
- **Quick Switcher Panel** — Hit `⌥Tab` anywhere on your computer to flash out a Spotlight-style central search engine and navigate Workspaces actively via keyboard typing filter instantly.
- **Launch At Login (`SMAppService`)** — Deep Apple Silicon architecture gracefully bootstraps via the `ServiceManagement` interface locking execution continuously natively in the background upon Macbook boot without ever touching your system Dock manually!

---

## 🛠 Installation

Currently, Deks is available to compile directly via the Swift Package Manager. 

1. **Clone the Repository:**
```bash
git clone https://github.com/NPX2218/deks.git
cd deks
```

2. **Build and Run the standard CLI Executable:**
```bash
swift run
```

*(Optional) Generate the Production Mac Application native `.app` bundle!*
```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```
This automatically compiles the optimized release binary, dynamically binds Apple `Info.plist` manifests, scales the `assets/deks-icon-512.png` into standard `.icns` vectors using the Mac CoreGraphics engine, and outputs a completed `Deks.app` bundle in the root repo for you to literally drag straight into your Mac `/Applications` folder!

### 🔒 Permissions Note
Deks heavily leverages the Apple **Accessibility API** and **CoreGraphics Window** architecture to scrape layouts, read Chromium tab groups identically, and manipulate window constraints flawlessly. 
The first time you execute `swift run`, macOS will securely prompt you to grant Accessibility access dynamically to your Terminal or IDE application. Once granted, restart the application to seamlessly bootstrap!

## 📦 Usage Guide

1. **Top Menu Bar Dropdown:** Upon execution, an invisible Deks icon will launch persistently inside your top-right Mac Menu Bar. Everything visual stems from this dropdown.
2. **Configuring Workspaces:** Simply click **Settings...** to bring up the Settings Dashboard.
3. **Adding Apps:** In Settings, Deks surfaces all actively tracked unassigned Application windows running currently natively globally. Drag and drop them physically into the Left context pane seamlessly.
4. **Renaming / Pausing RAM:** Select your active Workspace via the dropdown and type functionally to redefine the title, select a color bounding variable, or toggle Background Memory Freezing optionally per Workspace dynamically!

---
*Deks — your desk, your rules.*