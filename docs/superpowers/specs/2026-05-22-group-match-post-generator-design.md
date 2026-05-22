# Group Match Post Generator — Design Spec

## Overview

Add a post generator to each group card in the tournament's Groups tab. Users can upload match photos per group and download Instagram-ready images: one per match (photo + score overlay) and one group summary card (final standings).

## Entry Point & Toggle

In `GroupMatches.tsx`, each group card header gets a **round camera button** (dark circle, `bg-black/50` style matching the Instagram Post page). Tapping it toggles **post mode** for that group:

- **Off (default):** button is dark — match rows show normally, no upload UI visible.
- **On (active):** button turns yellow (`bg-yellow-400`) — per-match camera buttons appear on each row, and a download bar appears at the bottom of the group card.

Each group card manages its own independent `postModeActive` boolean — toggling one group does not affect others.

## Per-Match Photo Upload

When post mode is active, each match row shows a **small round camera button** (same dark circle style, `w-7 h-7`) on the right side of the row. Tapping it opens the native file picker for that match. Once a photo is selected:

- A green dot badge appears on the button (same as pattern used elsewhere).
- The photo is stored in local component state as `Record<matchId, HTMLImageElement>`.

A photo counter in the download bar shows `N of 6 photos`.

## Download Bar

At the bottom of a group card in post mode, a footer bar shows:
- Left: `"N of 6 photos"` label in muted text.
- Right: **round yellow download button** (`bg-yellow-400`, download arrow SVG — identical to the Instagram Post page button).

Tapping download generates all images and triggers batch download.

## What Gets Downloaded

For a group with at least one photo uploaded:

### Match posts (one per uploaded photo)
- Canvas: **1080 × 1350**
- Layer 1: user photo (`drawCoverFill` — reuse from `InstagramPostPage`)
- Layer 2: `drawHeader` (logo + "MAJADU FUN" band — reuse from `InstagramPostPage`)
- Layer 3: score footer — dark semi-transparent bar at the bottom with:
  - Pair A name (left) · Score in yellow `"21 – 15"` (center) · Pair B name (right)
  - Subtitle: `"GROUP A · MATCH 1"` in muted monospace
- Filename: `group-A-match-1.jpg`, `group-A-match-2.jpg`, etc.
- Matches without a photo are skipped.

### Group summary (always generated, one per group)
- Canvas: **1080 × 1350**
- Background: `storyBg` overlay (same as Instagram Post page)
- Dark card centered on top of background
- Header: `"FINAL STANDINGS"` label + `"GROUP A"` in yellow
- Table: same column layout as existing mini standings in `GroupMatches`:
  - Columns: `#` · Name · W · L · +/- · dot
  - Top 2 rows: yellow-tinted background row + yellow dot indicator
  - Rows 3–4: muted, no dot
- Filename: `group-A-summary.jpg`

## Canvas Utilities

Reuse directly from `InstagramPostPage.tsx`:
- `drawCoverFill` — photo layer
- `drawHeader` — header band with logo
- Overlay loading pattern (`loadImage`, `overlays` state)

The overlays (logo, storyBg) should be loaded once at the `TournamentPage` level and passed down, or loaded inside a new `GroupPostGenerator` utility module. Loading inside `GroupMatches` is simplest since that's where the feature lives.

## State

All state is **local to `GroupMatches`**:
- `postModeActive: boolean` — per group card (each group manages its own)
- `matchPhotos: Record<string, HTMLImageElement>` — keyed by `matchId`

No store changes. No server uploads.

## Files to Modify

- `src/components/tournament/GroupMatches.tsx` — main changes: toggle button, per-match upload buttons, download bar, canvas generation logic
- `src/utils/canvasPost.ts` *(new)* — extract `drawCoverFill`, `drawHeader`, `loadImage` from `InstagramPostPage.tsx` into a shared module so both pages use the same implementation

## Out of Scope

- Drag/reorder photos between matches
- Preview before download
- Story format (1080×1920) — post only
- Cloud upload of generated images
