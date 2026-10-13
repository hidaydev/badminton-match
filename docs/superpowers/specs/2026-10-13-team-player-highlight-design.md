# Team Player Highlight in Schedule Grid

**Date:** 2026-10-13  
**Status:** Approved

## Goal

Highlight players from Green Grove (champion) and Blue Waves (runner-up) in the session schedule grid (`SharedSessionPage` / `ScheduleGrid`) so viewers can instantly identify tournament team members in a regular badminton session.

## Visual Design

Each tournament team player gets:

1. **Small team logo** (14×14px, static) immediately before the player name
2. **Shimmer sweep animation** on the name text — a light beam glides left-to-right continuously in team color

### Colors

| Team | Name color | Shimmer highlight |
|------|-----------|-------------------|
| Green Grove | `#52c987` | `#c8fff0` |
| Blue Waves | `#5baee8` | `#c8e8ff` |

### Animation

```css
@keyframes shimmer {
  0%   { background-position: -200% center; }
  100% { background-position:  200% center; }
}

/* Name rendered as gradient text with shimmer sweep */
background: linear-gradient(90deg, #52c987 20%, #c8fff0 50%, #52c987 80%);
background-size: 200% auto;
-webkit-background-clip: text;
-webkit-text-fill-color: transparent;
background-clip: text;
animation: shimmer 2s linear infinite;
/* Blue Waves uses 0.5s delay so they don't pulse in perfect sync */
```

### Logo assets

- Green Grove: `/team-logos/Green_Grove-removebg-preview.png`
- Blue Waves: `/team-logos/Blue_Waves-removebg-preview.png`

## Data Model

The highlight mapping is a **hardcoded config** (not fetched from the API) since this is a one-time tournament display:

```ts
// apps/web/src/config/teamHighlights.ts
export const TEAM_HIGHLIGHTS: Record<string, { logo: string; logoSize: number; color: string; shimmer: string }> = {
  'Green Grove': {
    logo: '/team-logos/Green_Grove-removebg-preview.png',
    logoSize: 16,
    color: '#52c987',
    shimmer: '#c8fff0',
  },
  'Blue Waves': {
    logo: '/team-logos/Blue_Waves-removebg-preview.png',
    logoSize: 14,
    color: '#5baee8',
    shimmer: '#c8e8ff',
  },
}

/** Map from player name → team highlight (populated from tournament snapshot or hardcoded roster) */
export const HIGHLIGHTED_PLAYERS: Record<string, keyof typeof TEAM_HIGHLIGHTS> = {
  // populated at build time or fetched from tournament data
}
```

The player→team mapping needs to come from somewhere. Two options:

**Option 1 (recommended): Hardcoded player list** — simplest, no API change needed. A config file lists which player names belong to each team.

**Option 2: Derive from tournament snapshot** — fetch the team tournament, read team rosters. More dynamic but adds a query dependency to every session page.

→ **Go with Option 1** (hardcoded). The tournament is over; the roster won't change.

## Architecture

### New files

- `apps/web/src/config/teamHighlights.ts` — highlight config (colors, logos, player→team map)

### Modified files

- `apps/web/src/components/summary/ScheduleGrid.tsx` (or `PlayerChipRenderer.tsx`) — wrap player name in shimmer span + prepend logo when player is in highlight map
- `apps/web/src/index.css` — add `@keyframes shimmer` if not already present (it already exists via the celebration overlay work)

### Component change

`PlayerChipRenderer` (or wherever player names render in the grid) gets a lookup:

```tsx
import { HIGHLIGHTED_PLAYERS, TEAM_HIGHLIGHTS } from '../../config/teamHighlights'

const highlight = HIGHLIGHTED_PLAYERS[player.name]
const theme = highlight ? TEAM_HIGHLIGHTS[highlight] : null

// In render:
{theme ? (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>
    <img src={theme.logo} style={{ width: theme.logoSize, height: theme.logoSize, objectFit: 'contain' }} />
    <span style={{
      background: `linear-gradient(90deg, ${theme.color} 20%, ${theme.shimmer} 50%, ${theme.color} 80%)`,
      backgroundSize: '200% auto',
      WebkitBackgroundClip: 'text',
      WebkitTextFillColor: 'transparent',
      backgroundClip: 'text',
      animation: `shimmer 2s linear infinite`,
      animationDelay: highlight === 'Blue Waves' ? '0.5s' : '0s',
    }}>
      {player.name}
    </span>
  </span>
) : (
  <span>{player.name}</span>
)}
```

## Scope

- Only applies to the schedule grid (match rows)
- Does **not** affect Player Stats panel, absent markers, or swap/highlight mode overlays
- Does **not** add API endpoints or change the data model
- `@keyframes shimmer` already exists in `index.css` — no new CSS keyframe needed
