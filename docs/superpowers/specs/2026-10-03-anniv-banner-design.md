# Anniversary Banner Overlay — Design Spec

**Date:** 2026-10-03

## Goal

Full-screen anniversary "coming soon" overlay that appears on every app load with a dramatic player-reveal animation, dismissible by tapping anywhere.

## Assets

| File | Source | Position |
|------|--------|----------|
| `anniv-left.png` | `/Users/hidaydev/Downloads/left.png` | Left side — player group slides in from left |
| `anniv-right.png` | `/Users/hidaydev/Downloads/right.png` | Right side — player group slides in from right |
| `anniv-top.png` | `/Users/hidaydev/Downloads/top.png` | Top center — MAJADU 1ST ANNIVERSARY logo |
| `anniv-center.png` | `/Users/hidaydev/Downloads/center.png` | Center — team lineup logos |

## Layout

```
┌─────────────────────────────────────┐
│       [anniv-top.png — logo]        │
│                                     │
│  [anniv-left.png]  [anniv-right.png]│
│   (player group)   (player group)   │
│                                     │
│       [anniv-center.png]            │
│       (team logos lineup)           │
│                                     │
│      tap anywhere to dismiss        │
└─────────────────────────────────────┘
```

- Dark background (`bg-black/90`)
- Left and right player images positioned at screen edges, ~50% height, bottom-anchored
- Anniversary logo centered at top ~25% of screen
- Team lineup logos centered in the middle/lower area

## Animations (CSS keyframes, no dependencies)

| Element | Keyframe | Duration | Delay | Easing |
|---------|----------|----------|-------|--------|
| `anniv-left.png` | `slideInLeft`: `translateX(-110%)` → `0` | 0.7s | 0s | ease-out |
| `anniv-right.png` | `slideInRight`: `translateX(110%)` → `0` | 0.7s | 0s | ease-out |
| `anniv-top.png` | `slideInTop`: `translateY(-60px)` + opacity 0→1 | 0.6s | 0.3s | ease-out |
| `anniv-center.png` | `fadeInUp`: `translateY(30px)` + opacity 0→1 + scale 0.9→1 | 0.7s | 0.6s | ease-out |

## Behavior

- Mounts via `useState(true)` in `App.tsx` — no localStorage, shows on every page load/refresh
- Replaces `CelebrationOverlay` on this branch (swap import + state in `App.tsx`)
- `useEscapeKey(onDismiss)` for keyboard dismiss
- `tabIndex={-1}` + focus on mount
- `pointer-events: none` on image layers (tap hits backdrop)
- `onError` fallback on all `<img>` tags (hide if missing)

## Component

`apps/web/src/components/AnnivBannerOverlay.tsx`

## Files Changed

- Create: `apps/web/public/anniv-left.png`
- Create: `apps/web/public/anniv-right.png`
- Create: `apps/web/public/anniv-top.png`
- Create: `apps/web/public/anniv-center.png`
- Modify: `apps/web/src/index.css` (add 4 keyframes)
- Create: `apps/web/src/components/AnnivBannerOverlay.tsx`
- Modify: `apps/web/src/App.tsx` (swap CelebrationOverlay → AnnivBannerOverlay)
