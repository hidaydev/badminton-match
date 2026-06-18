# Bracket Post Feature Design

**Date:** 2026-05-22  
**Status:** Approved

## Overview

Add a post-mode feature to the bracket tab (BracketTab.tsx) that mirrors the group match post feature in GroupMatches.tsx. Each round column (QF / SF / Final) gets a camera icon toggle in its header. When active, each match card in that column shows a per-match camera icon for photo upload. A download icon (yellow round button) appears in the round header once at least one photo is ready, and downloads all ready posts for that round.

## UI Behaviour

### Round column headers
- Add a camera icon button (`w-8 h-8 rounded-full`) to each round header: **QF**, **SF**, **FINAL**
- Inactive: `bg-black/50` with white icon stroke
- Active: `bg-yellow-400` with black icon stroke
- When post mode is active **and** ≥1 photo is uploaded for that round, a yellow round download icon button appears next to the camera icon
- Download button: same `w-8 h-8 rounded-full bg-yellow-400` style with arrow-down SVG icon

### Per-match camera icon
- When a round's post mode is on, each match card in that round shows a small camera icon button on the right side (same as group match rows: `w-7 h-7 rounded-full bg-black/50`)
- A green dot indicator (`w-2 h-2 bg-green-500`) appears on the camera button when a photo has been uploaded for that match

### MatchCard refactor
Currently `MatchCard` renders as a `<button>` wrapper — which prevents nesting child buttons. Refactor to `<div>` wrapper with:
- Inner score `<button>` (same visual, same click handler)
- Sibling camera `<button>` on the right (only when `showPostIcon=true`)

## State

Added to `BracketTab`:
```ts
const [postModeRounds, setPostModeRounds] = useState<Record<string, boolean>>({})
const [bracketPhotos, setBracketPhotos] = useState<Record<string, HTMLImageElement>>({})
const activeUploadMatchId = useRef<string | null>(null)
const fileInputRef = useRef<HTMLInputElement>(null)
```

Overlay images loaded once via `useEffect` with `loadImage`:
- `/instagram-logo.png` → `logo`
- `/tournament-badge.png` → `badge`
- `/chevrons.png` → `chevrons`
- `/sponsor-logo.png` → `sponsor`

## Canvas Post Generation

Reuse the `drawMatchPost` function — extract it from `GroupMatches.tsx` into `src/utils/canvasPost.ts` as a named export so both GroupMatches and BracketTab can use it.

**Subtitle label mapping** (bottom of post footer):
| Match ID | Label |
|----------|-------|
| `qf-1` | `QUARTERFINAL · QF 1` |
| `qf-2` | `QUARTERFINAL · QF 2` |
| `qf-3` | `QUARTERFINAL · QF 3` |
| `qf-4` | `QUARTERFINAL · QF 4` |
| `sf-1` | `SEMIFINAL · SF 1` |
| `sf-2` | `SEMIFINAL · SF 2` |
| `final-1` | `FINAL` |
| `3rd-1` | `3RD PLACE` |

## Download

Same logic as `handleDownloadGroup`:
- Generate one canvas per match that has a photo for that round
- iOS: `navigator.share({ files })`
- Desktop: programmatic `<a download>` per file
- Filename: `bracket-{matchId}-{dateSuffix}.jpg` (e.g. `bracket-qf-1-20260522.jpg`)
- JPEG quality: 0.92

## Round → Match mapping

Each round's camera toggle and download applies to:
- `qf`: matches `qf-1`, `qf-2`, `qf-3`, `qf-4`
- `sf`: matches `sf-1`, `sf-2`
- `final`: matches `final-1`, `3rd-1`

## Files Changed

| File | Change |
|------|--------|
| `src/utils/canvasPost.ts` | Extract `drawMatchPost` from GroupMatches, export it |
| `src/components/tournament/GroupMatches.tsx` | Import `drawMatchPost` from canvasPost instead of defining it locally |
| `src/components/tournament/BracketTab.tsx` | Add post mode state, refactor MatchCard, add camera/download icons in headers, add upload/download handlers |
