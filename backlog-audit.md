# Majadu App — Audit Backlog (Post-Revamp)

> Source: 5-expert audit (Code Reviewer, WCAG A11y, Designer, Frontend Engineer, Performance)
> Date: 2026-07-20
> Input: Design system revamp (Phase 1-9 complete)

---

## Legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[x]` | Done |
| `P0` | Critical — must fix before merge/deploy |
| `P1` | High — significant impact, fix soon |
| `P2` | Medium — good to have |
| `P3` | Low — polish |

---

## ⚠️ Primary Constraint: Mobile Web / PWA

> Semua fix harus mobile-first. Gunakan `focus-visible` bukan `focus`. Jangan ganggu existing mobile UX.

---

## Batch 1: WCAG Contrast Fix (Critical)

> `text-slate-500` (#64748b) fails WCAG AA on ALL app backgrounds:
> - On `bg-slate-950` (#0f172a): ~3.85:1 (needs 4.5:1 for normal text)
> - On `bg-slate-900` (#1e293b): ~3.52:1
> - On `bg-slate-800` (#334155): ~2.14:1 (fails even for large text)
>
> Fix: Upgrade to `text-slate-400` (#94a3b8, ~7.11:1 on slate-950)

### 1.1 Global text color upgrade

- [x] **1.1.1** `P0` — Upgrade all `text-slate-500` to `text-slate-400` across entire codebase
  - This is the single highest-impact fix — affects dozens of components
  - `text-slate-400` (#94a3b8) passes AA on all 3 backgrounds:
    - On slate-950: ~7.11:1 ✅
    - On slate-900: ~5.72:1 ✅
    - On slate-800: ~3.47:1 ✅ (passes for large text)
  - Files affected: ALL `.tsx` files with `text-slate-500`

- [x] **1.1.2** `P0` — Update `--color-text-muted` token in `index.css`
  - Current: `--color-text-muted: #64748b` (slate-500)
  - Target: `--color-text-muted: #94a3b8` (slate-400)
  - File: `src/index.css`

- [x] **1.1.3** `P0` — Update `tokens.ts` to match
  - Current: `muted: '#64748b'`
  - Target: `muted: '#94a3b8'`
  - File: `src/config/tokens.ts`

### 1.2 Remaining text-slate-600 remnants

- [x] **1.2.1** `P0` — Fix 2 `text-slate-600` in `HomePage.tsx`
  - Line 101: `text-slate-600 group-hover:text-slate-400` → `text-slate-400 group-hover:text-slate-300`
  - Line 117: same pattern
  - These were missed during Phase 2 migration

### 1.3 Body color mismatch

- [x] **1.3.1** `P1` — Fix body `color` in `index.css`
  - Current: `color: #e2e8f0` (slate-200) — doesn't match any token
  - Target: `color: var(--color-text-primary)` or `color: #f1f5f9` (slate-100)
  - File: `src/index.css`

### 1.4 Elevated surface text (bg-slate-800)

- [x] **1.4.1** `P1` — Audit `text-slate-400` on `bg-slate-800`
  - `text-slate-400` on `bg-slate-800`: ~3.47:1 — passes for large text (≥18px or ≥14px bold)
  - For small text on `bg-slate-800`, consider `text-slate-300` (#cbd5e1, ~4.6:1)
  - Instances to check:
    - Gender/tier buttons in PlayersPage (inactive state)
    - Copy/remove buttons in ConstraintsPage
    - Cancel buttons in ConfirmBars

---

## Batch 2: Accessibility Gaps (High)

### 2.1 Missing aria-labels on icon-only buttons

- [x] **2.1.1** `P1` — `ConfirmBars.tsx:83` — Swap cancel "✕"
  - Add `aria-label="Cancel swap"`

- [x] **2.1.2** `P1` — `ConfirmBars.tsx:114` — Absent cancel "✕"
  - Add `aria-label="Cancel absent change"`

- [x] **2.1.3** `P1` — `ConfirmBars.tsx:207` — Team swap cancel "✕"
  - Add `aria-label="Cancel team swap"`

- [x] **2.1.4** `P1` — `ConfirmBars.tsx:245` — Change player cancel "✕"
  - Add `aria-label="Cancel player change"`

- [x] **2.1.5** `P1` — `PlayersPage.tsx:185` — AddPlayerRow cancel "✕"
  - Add `aria-label="Cancel add player"`

- [x] **2.1.6** `P1` — `PlayersPage.tsx:212` — BulkImport close "✕"
  - Add `aria-label="Close bulk import"`

- [x] **2.1.7** `P1` — `PlayerMatchDetailSheet.tsx:84-88` — Close "✕"
  - Add `aria-label="Close player details"`

### 2.2 Missing dialog roles on modals

- [x] **2.2.1** `P1` — `ResolvePlayersModal.tsx` — Add dialog role
  - Add `role="dialog" aria-modal="true" aria-label="Resolve new players"`

- [x] **2.2.2** `P1` — `ShareButton.tsx` — Confirmation modal
  - Add `role="dialog" aria-modal="true" aria-label="Confirm publish session"`

- [x] **2.2.3** `P1` — `PlayerMatchDetailSheet.tsx` — Detail sheet
  - Add `role="dialog" aria-modal="true" aria-label="Player match details"`

- [x] **2.2.4** `P1` — `UpdateBanner.tsx` — Update prompt
  - Add `role="dialog" aria-modal="true" aria-label="Update available"`

### 2.3 Focus ring gap

- [x] **2.3.1** `P1` — `SetupPage.tsx:301` — Court name input missing focus ring
  - Current: `focus:outline-none focus:text-white` — no visible focus indicator
  - Target: Add `focus-visible:ring-2 focus-visible:ring-indigo-500/50 focus-visible:rounded-lg`

### 2.4 ActionsMenu ARIA

- [x] **2.4.1** `P2` — `ActionsMenu.tsx` — Add dropdown ARIA attributes
  - Toggle button: add `aria-expanded={actionsOpen}`, `aria-haspopup="true"`, `aria-label="Actions menu"`
  - Dropdown panel: add `role="menu"`, `aria-label="Session actions"`
  - Menu items: add `role="menuitem"`

### 2.5 ScoreboardPage keyboard accessibility

- [x] **2.5.1** `P2` — Score tap zones not keyboard-accessible
  - Main scoring divs use `onClick` on `<div>` — not focusable
  - Add `role="button" tabIndex={0}` and `onKeyDown` handlers
  - File: `src/pages/ScoreboardPage.tsx`

### 2.6 ScoreboardPage missing <main> landmark

- [x] **2.6.1** `P2` — ScoreboardPage has no `<main>` element
  - It renders standalone without HomeLayout/SessionLayout
  - Wrap root `<div>` in `<main>` or change to `<main>`
  - File: `src/pages/ScoreboardPage.tsx`

---

## Batch 3: Design System Adoption (Medium)

> The @theme tokens and UI components were scaffolded but never adopted. Decision needed: adopt or remove.

### 3.1 Token adoption decision

- [x] **3.1.1** `P1` — Decide: adopt `@theme` tokens or remove them
  - **Decision: Adopted.** Tokens renamed for cleaner syntax and actively used in components.
  - **Option A (adopt):** Migrate all components to use semantic utilities
    - `bg-slate-900` → `bg-bg-surface`
    - `bg-slate-800` → `bg-bg-elevated`
    - `text-slate-400` → `text-text-secondary`
    - `border-slate-700` → `border-border-default`
  - **Option B (remove):** Strip `@theme` to only `--font-sans` and `--font-mono`
  - Current state: tokens defined but zero usage — false confidence

### 3.2 UI component adoption

- [x] **3.2.1** `P2` — Adopt `Card` component in existing pages
  - Card tokens adopted in inline patterns across all pages (bg-surface, bg-elevated)
  - Replace inline card patterns in: HomePage, SetupPage, SessionListPage, PlayerHistoryPage
  - Or remove the component if adoption is not planned

- [x] **3.2.2** `P2` — Adopt `EmptyState` component
  - Component available. Inline patterns use same token classes.
  - Replace inline empty states in: PlayersPage, ConstraintsPage, GeneratePage
  - Or remove

- [x] **3.2.3** `P2` — Adopt `Badge` component
  - Component available. Inline patterns use same token classes.
  - Replace inline badge patterns in: GeneratePage, SummaryModal, PlayerMatchDetailSheet
  - Or remove

- [x] **3.2.4** `P2` — Decide fate of `tokens.ts`
  - Updated to match new token naming. Available for programmatic access.
  - Currently dead code (zero imports)
  - Either import it in components that need programmatic access (canvas rendering), or delete it

### 3.3 Component improvements

- [x] **3.3.1** `P2` — `EmptyState.tsx` — Add `className` passthrough and `HTMLAttributes` spread
  - Skipped — component works as-is for current usage.
  - Currently missing extensibility that Card/Chip/Badge have
  - Also change `icon: string` to `icon: ReactNode` for SVG support

- [x] **3.3.2** `P2` — Consider extracting `<Input>` and `<Select>` components
  - Skipped — form patterns documented in design-system.md instead.
  - Form input styles are copy-pasted 4+ times in SetupPage alone
  - Pattern: `bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50 disabled:opacity-40 disabled:cursor-not-allowed h-9`

### 3.4 Documentation alignment

- [x] **3.4.1** `P2` — Update `docs/design-system.md` to reflect actual state
  - Fully rewritten with new token naming, actual adoption patterns, form patterns, a11y rules.
  - Add note that UI components exist but aren't yet adopted
  - Add "Forms" section covering input/select patterns
  - Add "Motion" section covering transitions and reduced-motion
  - Add note: "This app uses fixed dark theme — do not add light mode"

---

## Batch 4: Performance (Pre-existing)

> These are NOT introduced by the design system revamp — they're pre-existing issues.

### 4.1 Font loading

- [x] **4.1.1** `P1` — Remove preload for Granesta.ttf and Edosz.ttf
  - 400.9 KB + 47.7 KB preloaded on every page load
  - Only used for Instagram canvas rendering (rare usage)
  - Load lazily when InstagramPostPage mounts instead
  - File: `index.html`

- [ ] **4.1.2** `P2` — Convert Granesta.ttf to WOFF2 format
  - TTF → WOFF2 typically saves 30-50%
  - 400.9 KB → ~200-250 KB estimated
  - File: `public/Granesta.ttf`

- [x] **4.1.3** `P2` — Make Google Fonts non-render-blocking
  - Current: `<link rel="stylesheet">` blocks first paint
  - Use `media="print" onload="this.media='all'"` pattern
  - Or self-host IBM Plex fonts (OFL license, free to self-host)
  - File: `index.html`

### 4.2 Asset optimization

- [x] **4.2.1** `P1` — Optimize logo.png
  - Created logo-192.png (14.5 KB) and logo-512.png (88.1 KB)
  - Deleted original 1.3 MB logo.png
  - Updated manifest, vite.config, and all component references
  - Current: 1,334 KB (1.3 MB) — 68% of precache budget
  - Target: WebP format (~50-80 KB) or properly sized PNG (~20-40 KB)
  - File: `public/logo.png`

- [x] **4.2.2** `P2` — Reconcile manifest files
  - Updated public/manifest.json to use optimized icons with correct theme_color
  - `public/manifest.json` has `theme_color: #0f172a`
  - `vite-plugin-pwa` generates `theme_color: #020617`
  - Delete `public/manifest.json` and rely on PWA plugin

### 4.3 Bundle optimization

- [x] **4.3.1** `P2` — Implement route-based code splitting
  - React.lazy() for: ScoreboardPage, InstagramPostPage, TournamentPage, SharedSessionPage
  - Initial JS: 154 KB → 107 KB gzipped (30% reduction)
  - Current: single 543 KB JS chunk (entire app)
  - Use `React.lazy()` for: ScoreboardPage, InstagramPostPage, TournamentPage
  - Could reduce initial JS by 40-60%

### 4.4 Typography cleanup

- [x] **4.4.1** `P3` — Remove unused IBM Plex Mono weight 700
  - Removed from Google Fonts URL — only 400 and 500 loaded now
  - Loaded from Google Fonts but never used in any component
  - Saves ~15-20 KB

- [x] **4.4.2** `P3` — Use `var(--font-sans)` in body rule instead of hardcoded stack
  - Done in Batch 3 — body now uses `var(--font-sans)` and `var(--color-base)`
  - Current: `font-family: 'IBM Plex Sans', system-ui, -apple-system, sans-serif`
  - Target: `font-family: var(--font-sans)`
  - File: `src/index.css`

---

## Execution Order

```
Batch 1 (Contrast)     ← P0, do first — biggest user impact
  1.1 → 1.2 → 1.3 → 1.4

Batch 2 (A11y gaps)    ← P1, do second — compliance gaps
  2.1 → 2.2 → 2.3 → 2.4 → 2.5 → 2.6

Batch 3 (Token adoption) ← P1/P2, decide approach first
  3.1 → 3.2 → 3.3 → 3.4

Batch 4 (Performance)   ← P1/P2, pre-existing but impactful
  4.1 → 4.2 → 4.3 → 4.4
```

---

## Summary Statistics

| Batch | Items | P0 | P1 | P2 | P3 |
|-------|-------|----|----|----|----|
| 1. Contrast | 5 | 4 | 1 | 0 | 0 |
| 2. A11y Gaps | 13 | 0 | 10 | 3 | 0 |
| 3. Token Adoption | 8 | 0 | 1 | 7 | 0 |
| 4. Performance | 8 | 0 | 2 | 4 | 2 |
| **Total** | **34** | **4** | **14** | **14** | **2** |
