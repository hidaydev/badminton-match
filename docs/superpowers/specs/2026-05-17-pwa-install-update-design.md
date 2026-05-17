---
name: PWA Install Modal + Update Banner
description: Add service worker, install-to-homescreen modal (iOS/Android), and update notification banner
type: spec
date: 2026-05-17
---

# PWA Install Modal + Update Banner

## Overview

Add PWA support to the app so users can install it to their home screen and receive a top-bar notification when a new version is available.

## 1. PWA Infrastructure

Add `vite-plugin-pwa` to `vite.config.ts` with the following configuration:

- `registerType: 'prompt'` — new service worker waits; does not auto-reload
- `generateSW` mode — Workbox auto-generates the service worker, no manual SW file
- `manifest.json` — app name "Majadu App", dark slate theme color (`#020617`), `display: standalone`, icons (192×192 and 512×512 from `/logo.png`)
- `useRegisterSW` hook from `virtual:pwa-register/react` used to detect `needRefresh` and call `updateServiceWorker(true)` on user action

## 2. Install Detection

Three signals determine install state:

- **Android/Chrome**: listen for `beforeinstallprompt` event on `window`. Capture and hold it (`deferredPrompt`). Presence of this event means the browser considers the app installable and not yet installed.
- **iOS**: detect via `navigator.userAgent` matching `/iphone|ipad|ipod/i`. iOS never fires `beforeinstallprompt` — always show manual instruction flow.
- **Already installed**: check `window.matchMedia('(display-mode: standalone)').matches`. If true, skip all install UI.

A `usePwaInstall` hook encapsulates this logic and exposes:
- `isInstallable: boolean` — true if not in standalone mode and either Android prompt is available or iOS is detected
- `isIos: boolean`
- `prompt()` — triggers the deferred prompt on Android; no-op on iOS (modal shows instructions instead)

## 3. Install Modal

A bottom-sheet style modal (`InstallModal.tsx`) rendered in `HomeLayout` (so it's available on all home pages).

**Trigger conditions:**
- Auto-show: 1.5s after homepage (`/`) mounts, if `isInstallable` is true
- Manual: tapping the "Install App" menu item on the homepage

**Android variant:**
- Title: "Install Majadu App"
- Body: "Add to your home screen for quick access — works offline too."
- Primary button: "Install" → calls `prompt()`, closes modal on user accepting
- Secondary button: "Not now" → closes modal (no permanent dismiss flag; shows again next visit)

**iOS variant:**
- Title: "Install Majadu App"
- Step-by-step instructions with inline icons:
  1. Tap the **Share** icon (↑) in Safari's toolbar
  2. Scroll and tap **"Add to Home Screen"**
  3. Tap **"Add"** to confirm
- Close button: "Got it" → closes modal

**No permanent "don't show again"** — modal shows every visit to homepage until the app is in standalone mode.

## 4. Homepage Menu Item

Add an **"Install App"** grid card to `HomePage.tsx`, alongside the existing 2×2 grid items:

- Icon: 📲
- Label: "Install App"
- Description: "Add to your home screen"
- Action: opens `InstallModal`
- **Hidden** when `isInstallable` is false (i.e. already installed or browser doesn't support)

The grid currently has 5 items (odd layout). Adding "Install App" makes 6 — a clean 2×3 grid when visible.

## 5. Update Banner

A fixed bar at the top of the screen, rendered inside `HomeLayout` above the sticky header (or as an overlay above it, `z-50`).

- Visible only when `needRefresh` is true from `useRegisterSW`
- Content: `"New version available"` + **"Reload"** button
- Tapping Reload calls `updateServiceWorker(true)` — triggers `skipWaiting` in the SW then reloads the page
- No dismiss button — stays visible until the user reloads
- Styling: amber/yellow background to contrast with the dark slate theme, full-width

## 6. File Structure

```
src/
  hooks/
    usePwaInstall.ts       — install detection hook
  components/
    InstallModal.tsx       — install bottom-sheet modal
    UpdateBanner.tsx       — top update notification bar
    HomeLayout.tsx         — updated to render InstallModal + UpdateBanner
  pages/
    HomePage.tsx           — updated to add Install App card + auto-show trigger
vite.config.ts             — updated with vite-plugin-pwa config
```

## 7. Dependencies

- `vite-plugin-pwa` (devDependency) — generates SW and manifest
- `workbox-window` is pulled in transitively by `vite-plugin-pwa`

No new runtime dependencies needed — `useRegisterSW` is provided by the plugin's virtual module.
