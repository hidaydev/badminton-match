# Team Tournament · Photo & Instagram Post Feature

**Date:** 2026-09-12
**Status:** Approved

## Summary

Add photo upload + Instagram post export to the Team Tournament's Schedule tab and Final tab, mirroring the existing pattern in the classic tournament's `GroupMatches.tsx`.

Each group match generates up to 4 posts: 3 per-partai posts + 1 team-match summary post. The Final generates up to 5 posts: same 4 + a champion post.

---

## Decisions

| Question | Decision |
|---|---|
| Post scope | Both per-partai (3×) AND team-match summary (1×) |
| UI placement | Camera toggle on Schedule tab rows (like `GroupMatches.tsx`) |
| Final match | Per-partai + team summary + champion post |
| Summary post layout | Team names + overall score + partai list (Layout A) |
| Canvas approach | Reuse existing functions; one new `drawTeamMatchPost` |

---

## Files

### New
- `apps/web/src/components/tournament/TeamGroupSchedule.tsx`
  Extracts the Schedule tab group match rows from `TeamTournamentPage.tsx` and adds photo/post logic. Mirrors `GroupMatches.tsx` in structure.

### Modified
- `apps/web/src/utils/canvasPost.ts`
  Add `drawTeamMatchPost()` for the team-match summary post.
- `apps/web/src/pages/TeamTournamentPage.tsx`
  Replace inline schedule JSX (`tab === 'jadwal'`) with `<TeamGroupSchedule>`. Add champion photo upload + export to the Final tab.

---

## Component: TeamGroupSchedule

### Props
```ts
interface TeamGroupScheduleProps {
  teams: TeamTournamentSnapshot['teams']
  matches: TeamMatch[]
  onSave: (matches: TeamMatch[]) => void
  isSaving: boolean
}
```

### State
```ts
postModeMatches: Record<string, boolean>          // toggle per group match id
teamPhotos: Record<string, HTMLImageElement>       // matchId → team photo
partaiPhotos: Record<string, HTMLImageElement>     // `${matchId}-${partaiIdx}` → photo
overlays: { logo, chevrons, sponsor, badge }       // loaded once on mount
activeUploadKey: React.MutableRefObject<string|null>
fileInputRef: React.RefObject<HTMLInputElement>
```

### Download flow (per group match)
1. For each of 3 partai that has a photo + scores: `drawMatchPost(canvas, photo, nameA, nameB, scoreA, scoreB, subtitle, ...)` → JPEG file
2. If team photo uploaded: `drawTeamMatchPost(canvas, photo, teamAName, teamBName, aWins, bWins, partaiRows, subtitle, ...)` → JPEG file
3. `shareOrDownload(files, "TeamA vs TeamB")`

Upload key convention:
- `matchId` → team photo for that match
- `${matchId}-0`, `${matchId}-1`, `${matchId}-2` → partai 0, 1, 2 photos

---

## Canvas: `drawTeamMatchPost`

### Signature
```ts
export function drawTeamMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  teamAName: string,
  teamBName: string,
  teamAWins: number,
  teamBWins: number,
  partaiRows: {
    tier: string
    nameA: string
    nameB: string
    scoreA: number | null
    scoreB: number | null
  }[],
  subtitle: string,
  logo: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
): void
```

### Layers (1080×1350)
1. **Full-bleed photo** — `drawCoverFill(ctx, photo, W, H, 0, 0)`
2. **Chevrons** — top-right + mirrored top-left (same as `drawMatchPost`)
3. **Header band** — `drawTournamentHeader(ctx, W, logo)` (existing internal fn)
4. **Dark footer** (~280px from bottom):
   - `rgba(0,0,0,0.85)` fill rect
   - Sponsor logo centered at top of footer (if provided)
   - Team A name (left, white, bold 36px) | "X – Y" (center, accent, bold 42px monospace) | Team B name (right, muted, bold 36px)
   - Thin divider line (`rgba(250,204,21,0.25)`)
   - 3 partai rows (bold 22px): tier label (accent) | nameA (left, white) | score (center, accent) | nameB (right, muted)
   - Subtitle (bottom center, 18px monospace, muted)

Reuses all internal helpers already in `canvasPost.ts`: `drawCoverFill`, `drawTournamentHeader`, `truncateToWidth`.

---

## Final Tab: Champion Export

When `championName` is non-null (final match complete), show below the existing champion banner:

```
Champion photo:  [ 📷 Upload ]     (green dot when uploaded)
[ Download all posts ]             (disabled if no photos uploaded)
```

Download generates up to 5 files:
1. 3 partai posts (drawMatchPost per partai with photo)
2. Team summary post (drawTeamMatchPost)
3. Champion post (drawPositionPost reused — label "🏆 CHAMPION", name = championName)

Champion photo upload is a separate state slot (e.g. `championPhoto: HTMLImageElement | null`) managed in `TeamTournamentPage` since the Final tab is not extracted into `TeamGroupSchedule`.

---

## Design Notes

- Overlays loaded identically to `GroupMatches.tsx`: logo, badge, chevrons, sponsor, (no summaryBg needed)
- No new canvas assets required — all overlay PNGs already exist in `/public`
- Post mode is UI-only local state — no server persistence of photos
- Design polish is out of scope for this iteration; `drawTeamMatchPost` starts close to `drawMatchPost` and will be refined later
