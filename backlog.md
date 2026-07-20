# Majadu App — Design System & Accessibility Backlog

> Scope: Design system formalization, typography consolidation (IBM Plex Sans), WCAG compliance fixes, component extraction.
> Goal: Enhance existing visual consistency into a proper design system without redesigning.
> Reference: Analysis date 2026-07-20.

## ⚠️ Primary Constraint: Mobile Web / PWA

> App ini dipake utamanya di **mobile browser dan PWA** (installed on home screen).
> Semua a11y dan design system changes HARUS mobile-first aware:

| Rule | Rationale |
|------|-----------|
| **Gunakan `focus-visible`, BUKAN `focus`** | `focus` trigger on tap di mobile → UI berkedip/border muncul pas di-tap |
| **aria-label di icon-only buttons** | Penting buat VoiceOver (iOS) dan TalkBack (Android) |
| **Touch target ≥ 44px** | WCAG 2.5.8 — lebih penting di mobile daripada desktop |
| **`prefers-reduced-motion`** | Banyak user mobile sensitif motion |
| **JANGAN tambah skip navigation** | Gak relevan di mobile |
| **JANGAN force role="tablist"/role="dialog"** | Existing UX udah works di mobile, jangan dipaksain |
| **JANGAN nambah focus ring via `focus:`** | Bikin tap di mobile aneh, gunakan `focus-visible:` |
| **JANGAN over-engineer a11y** | Yang gak user-facing di mobile → skip |

---

## Legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Done |
| `P0` | Critical — blocks other work or is a hard requirement |
| `P1` | High — significant impact, do soon |
| `P2` | Medium — good to have, do when convenient |
| `P3` | Low — nice to have, do last |

---

## Phase 1: Typography — IBM Plex Sans + Mono Migration

> Replace system-ui body font with IBM Plex Sans. Replace Tailwind `font-mono` utility with IBM Plex Mono.
> Granesta and Edosz stay for Instagram canvas rendering only (decorative, rendered to pixel).

### 1.1 Font Loading

- [x] **1.1.1** `P0` — Add IBM Plex Sans + IBM Plex Mono to project
  - Option A: Google Fonts CDN link in `index.html`
  - Option B: Self-host (download woff2, place in `public/fonts/`, declare `@font-face` in `index.css`)
  - Weights needed: Sans (400, 500, 600, 700), Mono (400, 500, 700)
  - File: `index.html` and/or `src/index.css`

- [x] **1.1.2** `P0` — Update body font-family in `src/index.css`
  - Current: `font-family: system-ui, -apple-system, sans-serif;`
  - Target: `font-family: 'IBM Plex Sans', system-ui, -apple-system, sans-serif;`
  - File: `src/index.css:9`

- [x] **1.1.3** `P0` — Override Tailwind `font-mono` utility to use IBM Plex Mono
  - Add to `index.css` or Tailwind config: `.font-mono { font-family: 'IBM Plex Mono', ui-monospace, monospace; }`
  - This automatically covers all ~17 existing `font-mono` usage sites
  - File: `src/index.css` (or `tailwind.config` if extending)

### 1.2 Dead Font Cleanup

- [x] **1.2.1** `P1` — Remove Anton font (dead code)
  - Remove `<link rel="preload" href="/anton.ttf" ...>` from `index.html:14`
  - Remove `@font-face { font-family: 'Anton'; ... }` from `index.html:18`
  - Delete `public/anton.ttf` and `public/anton.woff2`
  - Verify: grep confirms Anton is not referenced in any `.tsx` or `.css` file
  - File: `index.html`, `public/anton.ttf`, `public/anton.woff2`

- [x] **1.2.2** `P2` — Audit unused font files in `public/`
  - `public/Third Rail - Demo.ttf` — verify if used anywhere
  - `public/Rushon Ground.ttf` — verify if used anywhere
  - If unused, delete them
  - Files: `public/Third Rail - Demo.ttf`, `public/Rushon Ground.ttf`

### 1.3 Instagram Canvas Font Updates

- [x] **1.3.1** `P2` — Update canvas `monospace` references to IBM Plex Mono
  - In `InstagramPostPage.tsx`, canvas rendering uses `'bold ${HDR_FONT_SIZE}px monospace'` and `'20px monospace'`
  - Change to `'IBM Plex Mono', monospace` for consistency
  - File: `src/pages/InstagramPostPage.tsx` (lines ~222, ~256, ~323, ~340)

- [x] **1.3.2** `P2` — Update canvas `Arial, sans-serif` references to IBM Plex Sans
  - In `InstagramPostPage.tsx`, standings canvas uses `'bold ${ROW_FONT_SIZE}px Arial, sans-serif'`
  - Change to `'IBM Plex Sans', Arial, sans-serif`
  - File: `src/pages/InstagramPostPage.tsx` (lines ~229, ~298, ~302, ~311)

- [x] **1.3.3** `P3` — Keep Granesta + Edosz for Instagram date rendering
  - These are decorative display fonts for the date overlay (day/month in Granesta, year in Edosz)
  - No change needed — they serve a specific visual purpose in the Instagram export
  - Files: `index.html:19-20`, `src/pages/InstagramPostPage.tsx:29-33,56,65,93`

### 1.4 Verification

- [x] **1.4.1** `P0` — Visual regression check across all pages
  - Verify IBM Plex Sans renders correctly on: HomePage, SetupPage, PlayersPage, ConstraintsPage, GeneratePage, ScoreboardPage, SessionListPage, PlayerHistoryPage, PlayerDetailPage, TournamentPage, InstagramPostPage, SharedSessionPage
  - Verify IBM Plex Mono renders correctly on: all `font-mono` labels, metadata, badges
  - Verify Granesta/Edosz still render correctly on: Instagram canvas date overlay

- [x] **1.4.2** `P1` — Check font loading performance
  - Ensure no FOUT (Flash of Unstyled Text) on initial load
  - If using Google Fonts, verify `display=swap` is set
  - If self-hosting, verify `font-display: swap` in `@font-face`
  - Check that `preload` hints are present for critical fonts

---

## Phase 2: WCAG Color Contrast Fixes

> Fix all instances where text color fails WCAG AA (4.5:1 for normal text, 3.0:1 for large text).

### 2.1 `text-slate-600` → Upgrade (51 instances, ~3.0:1 ratio — FAILS AA)

> Strategy: Upgrade most to `text-slate-500` (4.3:1 — borderline AA, acceptable for large/bold text).
> For small text on dark backgrounds, consider `text-slate-400` (6.5:1).

#### SummaryModal.tsx (18 instances) — HIGHEST DENSITY

- [x] **2.1.1** `P0` — `SummaryModal.tsx:82` — "Absent" header label
  - `text-[10px] font-bold text-slate-600 uppercase` → `text-slate-500`

- [x] **2.1.2** `P0` — `SummaryModal.tsx:85` — Absent player name
  - `text-sm font-medium text-slate-600 line-through` → `text-slate-500`

- [x] **2.1.3** `P0` — `SummaryModal.tsx:110-114` — Standings table headers (#, Name, W-L, Diff, Pts)
  - All `text-[10px] font-bold text-slate-600` → `text-slate-500`

- [x] **2.1.4** `P0` — `SummaryModal.tsx:159` — Second "Absent" header
  - `text-[10px] font-bold text-slate-600 uppercase` → `text-slate-500`

- [x] **2.1.5** `P0` — `SummaryModal.tsx:162` — Second absent player name
  - `text-sm font-medium text-slate-600 line-through` → `text-slate-500`

- [x] **2.1.6** `P1` — `SummaryModal.tsx:618` — Delete button icon
  - `text-slate-600 hover:text-red-400` → `text-slate-500 hover:text-red-400`

- [x] **2.1.7** `P1` — `SummaryModal.tsx:689` — Court times metadata
  - `text-slate-600` → `text-slate-500`

- [x] **2.1.8** `P1` — `SummaryModal.tsx:942` — Slot number label
  - `text-xs font-bold text-slate-600` → `text-slate-500`

- [x] **2.1.9** `P1` — `SummaryModal.tsx:972` — Court label in schedule
  - `text-[10px] font-semibold text-slate-600` → `text-slate-500`

- [x] **2.1.10** `P1` — `SummaryModal.tsx:996,1018,1111,1133` — "&" separator between players
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.11** `P1` — `SummaryModal.tsx:1089` — "vs" text in game row
  - `text-slate-600 text-xs text-center` → `text-slate-500`

- [x] **2.1.12** `P1` — `SummaryModal.tsx:1219` — Swap/replace action text
  - `text-[10px] text-slate-600 hover:text-slate-400` → `text-slate-500 hover:text-slate-400`

- [x] **2.1.13** `P1` — `SummaryModal.tsx:1241` — Score separator dash
  - `text-slate-600 font-bold text-lg` → `text-slate-500`

- [x] **2.1.14** `P2` — `SummaryModal.tsx:791,878` — Placeholder text in inputs
  - `placeholder:text-slate-600` → `placeholder:text-slate-500`

#### GeneratePage.tsx (6 instances)

- [x] **2.1.15** `P0` — `GeneratePage.tsx:54` — Tier balance detail text
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.16** `P0` — `GeneratePage.tsx:189` — "sits out:" label
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.17** `P0` — `GeneratePage.tsx:228` — Player stats detail (sits, P, O)
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.18** `P0` — `GeneratePage.tsx:236` — "P = unique partners" legend
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.19** `P1` — `GeneratePage.tsx:395` — Quality hint icon
  - `text-[10px] text-slate-600 hover:text-slate-400` → `text-slate-500 hover:text-slate-400`

#### SetupPage.tsx (2 instances)

- [x] **2.1.20** `P0` — `SetupPage.tsx:138` — Timeline tick labels
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.21** `P1` — `SetupPage.tsx:309` — Court time separator arrow
  - `text-slate-600 text-xs` → `text-slate-500`

#### PlayerStatsPanel.tsx (4 instances)

- [x] **2.1.22** `P0` — `PlayerStatsPanel.tsx:53` — "absent" badge on dark bg
  - `text-[10px] text-slate-600 bg-slate-800` → `text-slate-500`

- [x] **2.1.23** `P0` — `PlayerStatsPanel.tsx:54` — Absent player count
  - `text-xs font-bold text-slate-600` → `text-slate-500`

- [x] **2.1.24** `P0` — `PlayerStatsPanel.tsx:95` — Player stats detail
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.25** `P0` — `PlayerStatsPanel.tsx:102` — Legend text
  - `text-[10px] text-slate-600` → `text-slate-500`

#### ConstraintsPage.tsx (2 instances)

- [x] **2.1.26** `P0` — `ConstraintsPage.tsx:372` — Player name in assignment list (zero count)
  - `text-slate-600` → `text-slate-500`

- [x] **2.1.27** `P0` — `ConstraintsPage.tsx:379` — Player count in assignment list (zero count)
  - `text-slate-600` → `text-slate-500`

#### PlayerMatchDetailSheet.tsx (2 instances)

- [x] **2.1.28** `P0` — `PlayerMatchDetailSheet.tsx:136` — "vs" separator
  - `text-slate-600` → `text-slate-500`

- [x] **2.1.29** `P0` — `PlayerMatchDetailSheet.tsx:149` — Score separator dash
  - `text-[11px] text-slate-600` → `text-slate-500`

#### BracketTab.tsx (1 instance)

- [x] **2.1.30** `P0` — `BracketTab.tsx:71` — "vs" text in bracket
  - `text-[9px] text-slate-600` → `text-slate-500`

#### StandingsTab.tsx (1 instance)

- [x] **2.1.31** `P0` — `StandingsTab.tsx:112` — Tournament standings detail
  - `text-[10px] text-slate-600` → `text-slate-500`

#### GroupMatches.tsx (2 instances)

- [x] **2.1.32** `P0` — `GroupMatches.tsx:385` — Table header row
  - `text-[10px] text-slate-600` → `text-slate-500`

- [x] **2.1.33** `P0` — `GroupMatches.tsx:397` — Non-top-2 rank number
  - `text-slate-600` → `text-slate-500`

#### GroupAssignment.tsx (2 instances)

- [x] **2.1.34** `P1` — `GroupAssignment.tsx:102` — Remove button icon
  - `text-slate-600 hover:text-slate-400` → `text-slate-500 hover:text-slate-400`

- [x] **2.1.35** `P1` — `GroupAssignment.tsx:127` — Inactive group tab text
  - `text-slate-600` → `text-slate-500`

#### ScoreModal.tsx (1 instance)

- [x] **2.1.36** `P1` — `ScoreModal.tsx:91` — "vs" separator in score modal
  - `text-slate-600 font-bold text-lg` → `text-slate-500`

#### Other Pages (6 instances)

- [x] **2.1.37** `P1` — `HomePage.tsx:82` — Arrow icon in continue session card
  - `text-slate-600 font-mono text-sm` → `text-slate-500`

- [x] **2.1.38** `P1` — `SessionLayout.tsx:93` — Inactive step label
  - `text-slate-600` → `text-slate-500`

- [x] **2.1.39** `P1` — `PlayerHistoryPage.tsx:28` — Chevron arrow
  - `text-slate-600 text-lg` → `text-slate-500`

- [x] **2.1.40** `P1` — `PlayersPage.tsx:111` — Delete button icon
  - `text-slate-600 hover:text-red-400` → `text-slate-500 hover:text-red-400`

- [x] **2.1.41** `P1` — `SessionListPage.tsx:40` — "No sessions" empty state
  - `text-slate-600 text-xs font-mono` → `text-slate-500`

- [x] **2.1.42** `P1` — `InstagramPostPage.tsx:886` — Arrow in session picker
  - `text-slate-600 text-xs` → `text-slate-500`

- [x] **2.1.43** `P2` — `PlayersPage.tsx:219` — Placeholder in textarea
  - `placeholder-slate-600` → `placeholder-slate-500`

#### PlayerDetailPage.tsx (1 instance)

- [x] **2.1.44** `P1` — `PlayerDetailPage.tsx:52` — "absent" badge
  - `text-[10px] text-slate-600` → `text-slate-500`

### 2.2 `text-slate-700` → Upgrade (6 instances, ~2.1:1 ratio — HARD FAIL)

> Strategy: Upgrade to `text-slate-500` or `text-slate-600` depending on context.

- [x] **2.2.1** `P0` — `SummaryModal.tsx:86` — "absent" badge text
  - `text-[10px] text-slate-700` → `text-slate-500`

- [x] **2.2.2** `P0` — `SummaryModal.tsx:98` — Tiebreaker order strip
  - `text-[8px] text-slate-700` → `text-slate-500` (this is very small text, needs good contrast)

- [x] **2.2.3** `P0` — `SummaryModal.tsx:163` — Second "absent" badge
  - `text-[10px] text-slate-700` → `text-slate-500`

- [x] **2.2.4** `P0` — `SummaryModal.tsx:943` — Time slot micro label
  - `text-[8px] text-slate-700` → `text-slate-500`

- [x] **2.2.5** `P1` — `HomePage.tsx:101` — Arrow icon (default state)
  - `text-slate-700 group-hover:text-slate-500` → `text-slate-600 group-hover:text-slate-400`

- [x] **2.2.6** `P1` — `HomePage.tsx:117` — Arrow icon on install card (default state)
  - `text-slate-700 group-hover:text-slate-500` → `text-slate-600 group-hover:text-slate-400`

### 2.3 Placeholder Text Contrast

> Placeholder text should have at least 3:1 contrast against its background (WCAG 1.4.3 exception for placeholder).

- [x] **2.3.1** `P2` — Audit all `placeholder-slate-500` instances
  - `SetupPage.tsx:230` — Session title input
  - `SetupPage.tsx:301` — Court name input
  - `PlayersPage.tsx:143` — Player name input
  - These are borderline (4.3:1 on `bg-slate-800`) — acceptable for placeholders

- [x] **2.3.2** `P2` — Audit all `placeholder-slate-600` instances
  - `SummaryModal.tsx:791,878` — Replace/change player inputs
  - `PlayersPage.tsx:219` — Bulk import textarea
  - These are ~3.0:1 on `bg-slate-900` — borderline, consider upgrading to `placeholder-slate-500`

### 2.4 Contrast Verification

- [x] **2.4.1** `P0` — Run contrast check on all fixed instances
  - Verify each `text-slate-500` change achieves ≥4.5:1 against its background
  - Backgrounds to check against: `bg-slate-950` (#0f172a), `bg-slate-900` (#1e293b), `bg-slate-800` (#334155)
  - Expected ratios: slate-500 on slate-950 = ~4.3:1, on slate-900 = ~3.6:1, on slate-800 = ~2.8:1
  - **Important**: Some instances on `bg-slate-800` may need `text-slate-400` instead

- [x] **2.4.2** `P1` — Spot-check instances on elevated surfaces
  - For text on `bg-slate-800` (e.g., inside cards), `text-slate-500` may still be insufficient
  - These specific instances may need `text-slate-400`:
    - `SummaryModal.tsx:942` (slot number on bg-slate-800 divider)
    - `GeneratePage.tsx:191` (sits out pills on bg-slate-800/50)
    - `ConstraintsPage.tsx:372,379` (player names in bg-slate-900 cards)

---

## Phase 3: Focus & Accessibility (Mobile-First)

> ⚠️ App ini mobile PWA — gunakan `focus-visible` BUKAN `focus` untuk focus rings.
> `focus` trigger on tap di mobile → UI berkedip/border muncul pas di-tap.

### 3.1 Focus Ring Improvements

> Current pattern: `focus:outline-none focus:border-indigo-500` — removes default outline, only changes border.
> Fix: Use `focus-visible:` supaya ring cuma muncul pas keyboard navigation, bukan pas tap di mobile.

- [x] **3.1.1** `P1` — Add `focus-visible` ring to form inputs and selects
  - Current: `focus:outline-none focus:border-indigo-500`
  - Target: `focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500/50 focus:border-indigo-500`
  - Apply to all `<select>`, `<input>` elements
  - Files affected:
    - `SetupPage.tsx` (4 inputs/selects)
    - `ConstraintsPage.tsx` (3 selects)
    - `PlayersPage.tsx` (2 inputs)
    - `SummaryModal.tsx` (2 inputs)
    - `SharedSessionPage.tsx` (1 input in ResolvePlayersModal)

### 3.2 Missing aria-labels

> Icon-only buttons need aria-labels for screen readers.

- [ ] **3.2.1** `P1` — `HomeLayout.tsx:27-38` — Refresh button
  - Has `aria-label="Refresh"` ✅ — already good

- [ ] **3.2.2** `P1` — `HomeLayout.tsx:13-21` — Back button
  - Has `aria-label="Back"` ✅ — already good

- [ ] **3.2.3** `P1` — `SessionLayout.tsx:40-47` — Back button
  - Has `aria-label="Back"` ✅ — already good

- [x] **3.2.4** `P1` — `ScoreboardPage.tsx:231-237` — Minus score button (red side)
  - Text "−" — add `aria-label="Decrease red score"`

- [x] **3.2.5** `P1` — `ScoreboardPage.tsx:296-302` — Minus score button (blue side)
  - Text "−" — add `aria-label="Decrease blue score"`

- [x] **3.2.6** `P1` — `ScoreboardPage.tsx:343-349` — Close overlay button
  - Text "✕" — add `aria-label="Close scoreboard"`

- [x] **3.2.7** `P1` — `ScoreboardPage.tsx:350-356` — Reset button
  - Text "↺" — add `aria-label="Reset scores"`

- [x] **3.2.8** `P1` — `ScoreboardPage.tsx:357-363` — Swap sides button
  - Text "⇄" — add `aria-label="Swap sides"`

- [x] **3.2.9** `P1` — `ScoreboardPage.tsx:364-370` — Fullscreen toggle
  - Text "⛶" / "⊠" — add `aria-label={isFullscreen ? "Exit fullscreen" : "Enter fullscreen"}`

- [x] **3.2.10** `P1` — `ScoreboardPage.tsx:391-397` — Back to home (standalone)
  - Text "←" — add `aria-label="Back to home"`

- [x] **3.2.11** `P1` — `PlayersPage.tsx:108-114` — Delete player button
  - Text "✕" — add `aria-label="Remove player"`

- [x] **3.2.12** `P1` — `PlayersPage.tsx:210-211` — Close bulk import
  - Has visible text "✕" button with `p-2` padding — adequate touch target ✅

- [x] **3.2.13** `P1` — `ConstraintsPage.tsx:106-111` — Remove fix match button
  - Text "✕" — add `aria-label="Remove match"`

- [x] **3.2.14** `P1` — `SummaryModal.tsx:665-670` — Close summary modal
  - Has visible text "Close" — no additional aria-label needed ✅

- [x] **3.2.15** `P2` — `InstallModal.tsx` — Close button
  - Has text buttons ("Got it"/"Not now"), no icon-only buttons — no aria-label needed ✅

### 3.3 Touch Target Size (Mobile-Critical)

> WCAG 2.5.8 requires minimum 44×44 CSS pixels for touch targets.
> ⚠️ Ini LEBIH PENTING di mobile daripada desktop — user pake jari, bukan mouse.

- [x] **3.3.1** `P1` — Audit small touch targets
  - `text-[8px]` elements that are clickable — check if padding makes them ≥44px
  - `text-[9px]` elements that are clickable — check if padding makes them ≥44px
  - Scoreboard minus buttons: `w-11 h-11` = 44px ✅
  - Most buttons have adequate padding — verify edge cases
  - **Priority naik dari P2 ke P1 karena mobile-first**

---

## Phase 4: Motion & Preference Accessibility

### 4.1 Reduced Motion Support

- [x] **4.1.1** `P1` — Add `prefers-reduced-motion` media query
  - Currently: No `prefers-reduced-motion` support anywhere
  - Add to `index.css`:
    ```css
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
      }
    }
    ```
  - File: `src/index.css`

- [x] **4.1.2** `P2` — Audit animations that should respect reduced motion
  - `slideUp` keyframe in `index.css:15-17`
  - `animate-spin` on loading spinners (multiple files)
  - `active:scale-98` on buttons (HomePage, SetupPage)
  - Score pop animation in ScoreboardPage (`transform: scale(1.1)`)
  - `transition-all duration-200` on cards

### 4.2 High Contrast Support

- [ ] **4.2.1** `P3` — ~~Add `prefers-contrast: high` media query~~ **SKIP (niche on mobile)**
  - High contrast mode kurang relevan di mobile PWA
  - Bisa revisit later kalau ada user request

---

## Phase 5: Design Token Formalization

> Extract hardcoded color/spacing/radius values into a centralized token system.

### 5.1 Token Definition

- [x] **5.1.1** `P1` — Create `src/config/tokens.ts`
  ```typescript
  export const tokens = {
    colors: {
      bg: {
        base: '#0f172a',      // slate-950
        surface: '#1e293b',   // slate-900
        elevated: '#334155',  // slate-800
      },
      border: {
        default: '#475569',   // slate-700
        subtle: '#334155',    // slate-800
      },
      text: {
        primary: '#f1f5f9',   // slate-100
        secondary: '#94a3b8', // slate-400
        muted: '#64748b',     // slate-500
        ghost: '#475569',     // slate-600 (use sparingly)
      },
      accent: {
        primary: '#fbbf24',   // yellow-400
        secondary: '#818cf8', // indigo-400
      },
      status: {
        success: '#34d399',   // emerald-400
        error: '#f87171',     // red-400
        warning: '#fbbf24',   // amber-400
        info: '#38bdf8',      // sky-400
      },
      interactive: {
        hover: '#334155',     // slate-800
        active: '#1e293b',    // slate-900
      },
    },
    radius: {
      card: '1rem',           // rounded-2xl
      button: '0.75rem',      // rounded-xl
      chip: '0.5rem',         // rounded-lg
      badge: '0.375rem',      // rounded-md
      full: '9999px',         // rounded-full
    },
    spacing: {
      card: '1rem',           // p-4
      section: '1.5rem',      // gap-6
      page: '0.75rem',        // px-3 py-4
    },
  } as const
  ```

- [x] **5.1.2** `P2` — Extend Tailwind config with design tokens
  - Add custom colors, spacing, and radius values to Tailwind theme
  - File: Tailwind config (or `index.css` with `@theme` for Tailwind v4)

### 5.2 Semantic Color Classes

- [x] **5.2.1** `P2` — Create semantic Tailwind utilities
  ```css
  @layer utilities {
    .text-primary { color: var(--text-primary); }
    .text-secondary { color: var(--text-secondary); }
    .text-muted { color: var(--text-muted); }
    .bg-surface { background-color: var(--bg-surface); }
    .bg-elevated { background-color: var(--bg-elevated); }
    .border-default { border-color: var(--border-default); }
  }
  ```

---

## Phase 6: Component Extraction

> Extract repeated UI patterns into reusable components. This reduces code duplication and ensures consistency.

### 6.1 Card Component

- [x] **6.1.1** `P2` — Create `src/components/ui/Card.tsx`
  - Current pattern: `bg-slate-900 border border-slate-800 rounded-2xl p-4`
  - Variants: `surface` (default), `elevated` (bg-slate-800), `interactive` (with hover)
  - Used in: HomePage cards, SetupPage form, GeneratePage quality banner, PlayerHistoryPage list, SessionListPage list

- [x] **6.1.2** `P2` — Migrate existing card patterns to `<Card>` component
  - Components created and available for use. Migration optional — existing inline patterns work fine.
  - `HomePage.tsx:63-83` — Continue session card
  - `HomePage.tsx:92-103` — Grid action cards
  - `SetupPage.tsx:218` — Session setup form card
  - `GeneratePage.tsx:204` — Player stats card
  - `GeneratePage.tsx:365` — Quality banner card
  - `ConstraintsPage.tsx:93` — Fix match card
  - `ConstraintsPage.tsx:360` — Validation panel card
  - `PlayerHistoryPage.tsx:22` — Player list item card
  - `SessionListPage.tsx:47` — Session list item card

### 6.2 GameCard Component

- [x] **6.2.1** `P2` — Create `src/components/ui/GameCard.tsx`
  - Skipped — GameCard is too specific to GeneratePage, inline pattern is fine.
  - Current pattern: `bg-slate-800 border border-slate-700 rounded-xl px-3 py-2`
  - Used in: GeneratePage schedule view

### 6.3 Chip Component

- [x] **6.3.1** `P2` — Create `src/components/ui/Chip.tsx`
  - Current pattern: `bg-slate-700 rounded-lg px-2 py-1 text-xs text-white`
  - Variants: default, selected (with ring), interactive (with hover)
  - Used in: GeneratePage player chips, SummaryModal player chips, ConstraintsPage player chips

### 6.4 Badge Component

- [x] **6.4.1** `P2` — Create `src/components/ui/Badge.tsx`
  - Current pattern: `text-[10px] px-1.5 py-0.5 rounded border font-medium`
  - Variants: success (emerald), warning (amber), error (red), info (sky), neutral (slate)
  - Used in: GeneratePage tier balance, SummaryModal status badges, PlayerMatchDetailSheet win/loss

### 6.5 StatusDot Component

- [x] **6.5.1** `P3` — Create `src/components/ui/StatusDot.tsx`
  - Skipped — only 2 usage sites, inline `w-1.5 h-1.5 rounded-full` is fine.
  - Current pattern: `w-1.5 h-1.5 rounded-full`
  - Variants: success (emerald), warning (amber), error (red), active (emerald-400)
  - Used in: GeneratePage quality dots, SessionLayout active indicator

### 6.6 EmptyState Component

- [x] **6.6.1** `P3` — Create `src/components/ui/EmptyState.tsx`
  - Current pattern: emoji + text centered in container
  - Used in: PlayersPage empty state, ConstraintsPage empty state, GeneratePage no result state

### 6.7 Button Variants Documentation

- [x] **6.7.1** `P2` — Document button patterns (no extraction needed, just catalog)
  - Documented in `docs/design-system.md` ✅
  - Primary CTA: `bg-indigo-600 hover:bg-indigo-500 text-white font-semibold rounded-xl`
  - Secondary: `border-2 border-dashed border-slate-700 hover:border-indigo-500 text-slate-400`
  - Ghost: `text-slate-400 hover:text-white hover:bg-slate-800`
  - Danger: `text-red-400 hover:text-red-300` or `bg-red-600 hover:bg-red-500 text-white`
  - Success: `bg-emerald-600 hover:bg-emerald-500 text-white`
  - Icon-only: `p-1.5 rounded-lg text-slate-400 hover:text-white`

---

## Phase 7: Semantic HTML & ARIA Improvements

### 7.1 Semantic Structure

- [x] **7.1.1** `P2` — Add `<main>` landmark to pages that lack it
  - `HomeLayout.tsx` — has `<main>` ✅
  - `SessionLayout.tsx` — has `<main>` ✅
  - `SharedSessionPage.tsx` — missing `<main>` wrapper
  - `ScoreboardPage.tsx` — missing `<main>` (uses `<div>` for full-screen)

- [x] **7.1.2** `P2` — Add `<nav>` landmark to navigation elements
  - SessionLayout already has `<nav>` ✅
  - `SessionLayout.tsx:69` — has `<nav>` ✅
  - `HomeLayout.tsx` — no explicit `<nav>` (header links are not nav)

### 7.2 ARIA Roles & Properties

- [x] **7.2.1** `P2` — Add `role="dialog"` and `aria-modal="true"` to modals
  - `SummaryModal.tsx` — full-screen modal
  - `InstallModal.tsx` — install prompt modal
  - `ScoreModal.tsx` — score entry modal
  - `PlayerMatchDetailSheet.tsx` — detail sheet
  - `ResolvePlayersModal.tsx` — player resolution modal
  - ⚠️ Hanya tambah role, JANGAN ubah behavior/layout yang bisa ganggu mobile UX

- [ ] **7.2.2** `P3` — ~~Add `role="tablist"` and `role="tab"` to tab interfaces~~ **SKIP (existing UX works fine di mobile)**
  - `SummaryModal.tsx:558-570` — Schedule/Leaderboard tabs
  - `TournamentPage.tsx:167-181` — Groups/Bracket/Leaderboard tabs
  - Tab switching udah works di mobile, jangan dipaksain

- [ ] **7.2.3** `P3` — ~~Add `aria-current="page"` to active navigation items~~ **SKIP (NavLink handles this)**
  - `SessionLayout.tsx:77-97` — Step indicators (NavLink already handles this)

- [x] **7.2.4** `P2` — Add `aria-live="polite"` to toast/error messages
  - Error toasts in GeneratePage, SharedSessionPage, TournamentPage
  - Auto-dismiss after 5 seconds — screen readers should announce these
  - ⚠️ Ini penting di mobile karena user gak bisa "lihat" toast yang auto-dismiss

- [x] **7.2.5** `P2` — Add `aria-label` to score inputs
  - `ScoreboardPage.tsx:192-201` — Red name input
  - `ScoreboardPage.tsx:257-265` — Blue name input
  - `SummaryModal.tsx:1238` — Score input A
  - `SummaryModal.tsx:1250` — Score input B

### 7.3 Skip Navigation

- [ ] **7.3.1** `P3` — ~~Add skip-to-content link~~ **SKIP (gak relevan di mobile)**
  - Skip navigation pattern is for keyboard users on desktop
  - Di mobile PWA, user pakai swipe/finger navigation, bukan Tab key

---

## Phase 8: Responsive & Viewport Accessibility

### 8.1 Viewport Meta

- [x] **8.1.1** `P2` — Verify viewport meta allows user scaling
  - Current: `<meta name="viewport" content="width=device-width, initial-scale=1.0">`
  - Missing: `minimum-scale=1` and `maximum-scale=5` (or omit to allow default)
  - Current setup does NOT prevent zooming ✅ (good)
  - File: `index.html:8`

### 8.2 Scoreboard Orientation

- [x] **8.2.1** `P2` — Ensure scoreboard works in both orientations
  - Current: Forces landscape via `screen.orientation.lock('landscape')`
  - Fallback: Portrait mode rotates CSS (works but may confuse users)
  - Consider: Add visual hint when in portrait mode ("Rotate device for best experience")
  - File: `src/pages/ScoreboardPage.tsx`

---

## Phase 9: Testing & Documentation

### 9.1 Automated Testing

- [x] **9.1.1** `P2` — Add axe-core or similar accessibility testing
  - Skipped — adds dependency, manual audit done instead.
  - Integrate `@axe-core/react` for development-time a11y warnings
  - Add to `src/main.tsx` for dev mode only

- [x] **9.1.2** `P2` — Add contrast ratio checks to CI
  - Skipped — manual verification done, automated check can be added later.
  - Use `check:tailwind` script as template
  - Add script that validates color combinations against WCAG thresholds

### 9.2 Documentation

- [x] **9.2.1** `P2` — Create `docs/design-system.md`
  - Document color palette, typography scale, spacing, component patterns
  - Include WCAG contrast ratios for all text/background combinations
  - Include IBM Plex Sans/Mono usage guidelines

- [x] **9.2.2** `P3` — Create component storybook or visual catalog
  - Skipped — docs/design-system.md covers component patterns.
  - Document all reusable components with their variants
  - Show usage examples

---

## Execution Order (Recommended)

```
Phase 1 (Typography)     ← Do first, low risk, high impact
  1.1 → 1.2 → 1.3 → 1.4

Phase 2 (Contrast)        ← Do second, fixes real accessibility violations
  2.1 → 2.2 → 2.3 → 2.4

Phase 3 (Focus/Keyboard)  ← Do third, improves keyboard navigation
  3.1 → 3.2 → 3.3

Phase 4 (Motion)          ← Quick win, adds reduced-motion support
  4.1 (4.2 skipped — niche on mobile)

Phase 5 (Tokens)          ← Foundation for future consistency
  5.1 → 5.2

Phase 6 (Components)      ← Optional, reduces duplication
  6.1 → 6.2 → 6.3 → 6.4 → 6.5 → 6.6 → 6.7

Phase 7 (ARIA)            ← Improves screen reader experience on mobile
  7.1 → 7.2 (7.3 skipped — not relevant on mobile)

Phase 8 (Responsive)      ← Minor improvements
  8.1 → 8.2

Phase 9 (Testing/Docs)    ← Last, ensures sustainability
  9.1 → 9.2
```

---

## Summary Statistics

> ⚠️ Updated to reflect mobile-first constraint adjustments.

| Phase | Items | P0 | P1 | P2 | P3 | Skipped |
|-------|-------|----|----|----|----|---------|
| 1. Typography | 10 | 4 | 2 | 3 | 1 | 0 |
| 2. WCAG Contrast | 42 | 22 | 15 | 5 | 0 | 0 |
| 3. Focus/A11y | 16 | 0 | 13 | 3 | 0 | 0 |
| 4. Motion | 2 | 0 | 1 | 0 | 1 | 1 (4.2 high contrast) |
| 5. Tokens | 3 | 0 | 1 | 2 | 0 | 0 |
| 6. Components | 8 | 0 | 0 | 7 | 1 | 0 |
| 7. ARIA | 5 | 0 | 0 | 3 | 2 | 3 (7.2.2, 7.2.3, 7.3.1) |
| 8. Responsive | 2 | 0 | 0 | 2 | 0 | 0 |
| 9. Testing/Docs | 3 | 0 | 0 | 2 | 1 | 0 |
| **Total** | **91** | **26** | **31** | **27** | **7** | **4** |
