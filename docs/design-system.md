# Majadu App — Design System

> Formalized and adopted across the codebase. Last updated: 2026-11-07.

## Typography

| Role | Font | Weight | Tailwind | Usage |
|------|------|--------|----------|-------|
| Body | IBM Plex Sans | 400, 500, 600, 700 | `font-sans` | All UI text |
| Monospace | IBM Plex Mono | 400, 500 | `font-mono` | Labels, metadata, timestamps |
| Decorative | Road Rage + Edosz | — | — | Instagram canvas date overlay only |

IBM Plex Sans/Mono and Road Rage & Edosz are all self-hosted through `@font-face`
in `apps/web/index.html` (`display=swap`, files in `apps/web/public/fonts/` and
`apps/web/public/`). Body uses `var(--font-sans)`.
Road Rage is applied with a −9° skew so that its posture resembles Granesta v1.
Both are third-party files: see `THIRD-PARTY-NOTICES.md`.

## Color Tokens (Tailwind v4 `@theme`)

> These are the actual tokens used in components. Defined in the `@theme` block of
> `apps/web/src/index.css`. Contrast ratios are computed against `--color-ground`.

### Background
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-ground` | `#0b0e13` | `bg-ground` | Page background |
| `--color-surface` | `#14181f` | `bg-surface` | Cards, panels |
| `--color-elevated` | `#1c212b` | `bg-elevated` | Inner cards, inputs |

### Border
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-border` | `#2a313c` | `border-border` | Visible borders |
| `--color-border-subtle` | `#22272f` | `border-border-subtle` | Dividers, card borders |

### Text (WCAG AA on `bg-ground`)
| Token | Hex | Tailwind class | Ratio |
|-------|-----|----------------|-------|
| `--color-fg` | `#eef0f3` | `text-fg` | ~16.9:1 |
| `--color-fg-dim` | `#8b939c` | `text-fg-dim` | ~6.2:1 |

### Accent
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-accent` | `#e3b341` | `text-accent` | Brand, CTA, highlights |
| `--color-accent-alt` | `#e3b341` | `text-accent-alt` | Interactive, links (now the same as `accent`) |

### Status
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-success` | `#43a57d` | `text-success` | Positive states |
| `--color-error` | `#d65a5a` | `text-error` | Errors, destructive |
| `--color-warning` | `#e3b341` | `text-warning` | Warnings (same as `accent`) |
| `--color-info` | `#5b8fbd` | `text-info` | Informational |

## Token Usage in Components

The migration to semantic tokens is not 100% done; some components still use raw
palette classes (`slate-*`, `indigo-*`). The intended equivalents:

| Pattern | Raw Tailwind | Semantic Token |
|---------|-------------|----------------|
| Page background | `bg-slate-950` | `bg-ground` |
| Card surface | `bg-slate-900 border border-slate-800` | `bg-surface border border-border-subtle` |
| Elevated surface | `bg-slate-800 border border-slate-700` | `bg-elevated border border-border` |
| Body text | `text-slate-100` | `text-fg` |
| Dimmed text | `text-slate-400` | `text-fg-dim` |
| Brand accent | `text-yellow-400` | `text-accent` |
| Interactive | `text-indigo-400` | `text-accent-alt` |

## Typography Scale

| Level | Classes | Usage |
|-------|---------|-------|
| Page Title | `text-xl sm:text-2xl font-bold text-white` | H2 headings |
| Section Title | `text-sm font-semibold text-white` | Sub-sections |
| Body | `text-sm text-fg-dim` | Descriptions |
| Label | `text-xs text-fg-dim` | Form labels |
| Meta | `text-[10px] font-mono text-fg-dim uppercase` | Timestamps, badges |
| Micro | `text-[8px] text-fg-dim` | Tiebreaker info |

## Spacing & Radius

The scales live in `@theme` (`--spacing`, `--radius-*`, `--shadow-*`, `--ease-*`).
Four spacing steps, three radii, three elevations, two durations.

| Step | Token | Tailwind | Usage |
|------|-------|----------|-------|
| `0.5rem` | Spacing | `p-2` / `gap-2` | Chip and icon padding |
| `0.75rem` | Spacing | `p-3` / `gap-3` | Row padding |
| `1rem` | Spacing | `p-4` | Card padding |
| `1.5rem` | Spacing | `gap-6` | Section gaps |

| Radius | Token | Tailwind | Usage |
|--------|-------|----------|-------|
| `0.5rem` | `--radius-lg` | `rounded-lg` | Chips, inputs |
| `0.75rem` | `--radius-xl` | `rounded-xl` | Buttons |
| `1rem` | `--radius-2xl` | `rounded-2xl` | Cards |

| Elevation | Token | Tailwind | Usage |
|-----------|-------|----------|-------|
| Raised | `--shadow-sm` | `shadow-sm` | Chips, badges |
| Panel | `--shadow-md` | `shadow-md` | Cards, menus |
| Sheet | `--shadow-lg` | `shadow-lg` | Overlays |

## Component Patterns

Components follow the semantic token system. Key patterns:

- **Cards** use `bg-surface border border-border-subtle rounded-2xl p-4`
- **Chips** use `bg-elevated border border-border rounded-lg` with variant colors
- **Badges** use inline styling with status colors (`success`, `error`, `warning`, `info`)
- **Empty states** use centered layout with icon + title + description

## Button Variants (inline)

| Variant | Classes |
|---------|---------|
| Primary | `bg-accent text-ground font-semibold rounded-xl min-h-11 px-4` |
| Secondary | `border border-border text-fg hover:bg-elevated rounded-xl min-h-11 px-4` |
| Danger | `border border-border text-error hover:bg-elevated rounded-xl min-h-11 px-4` |
| Icon-only | `min-h-11 min-w-11 inline-flex items-center justify-center rounded-lg text-fg-dim` |

Legacy screens still spell the primary CTA as `bg-indigo-400 text-slate-950`. The
palette remap in `index.css` renders that as `accent`, so the difference is
naming, not colour; migration is cosmetic and can wait.

Dense rows (the played toggle, tournament camera buttons) keep a 24-32px visual
box and expand the hit area with `hit44` from
`apps/web/src/legacy/components/hitTarget.ts`.

## Form Patterns

```tsx
// Input and Select share one recipe; components/Field.tsx owns it.
className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3
  text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent
  disabled:opacity-60"

// The control is the child of a <label>. That is what gives it an accessible
// name, so there is no id/htmlFor plumbing.
```

## Overlay (bottom sheet)

One primitive, one variant. `apps/web/src/components/Overlay.tsx` is the only
shell for modal dialogs; new usages import this component instead of copying
`fixed inset-0` again. Its test is in `Overlay.test.tsx`.

### Props

| Prop | Type | Default | Notes |
|------|------|---------|------------|
| `onClose` | `() => void` | required | Called by Escape, scrim tap, and the ✕ button |
| `title` | `ReactNode` | required | Rendered as `<h2 id>`, so the dialog name comes from the title |
| `description` | `ReactNode` | - | `<p>` below the title |
| `children` | `ReactNode` | required | Sheet content; the only area that scrolls |
| `footer` | `ReactNode` | - | Actions at the bottom, inside the safe area |
| `dismissible` | `boolean` | `true` | `false` while saving: Escape and scrim are ignored, ✕ is not rendered |
| `labelledBy` | `string` | - | Escape hatch when a custom heading is rendered inside `children`; the default `<h2>` is not rendered |

### Class recipe

```tsx
scrim  : fixed inset-0 z-50 flex items-end justify-center bg-black/60
sheet  : relative flex w-full max-w-lg max-h-dvh flex-col overflow-hidden
         rounded-t-3xl border-t border-border-subtle bg-surface pb-[max(0.75rem,env(safe-area-inset-bottom))]
         shadow-2xl
handle : mx-auto mt-3 mb-1 h-1 w-10 shrink-0 rounded-full bg-border
header : shrink-0 px-5 pt-3 pb-2            (h2 text-base font-bold text-fg)
body   : min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pb-4
footer : shrink-0 border-t border-border-subtle px-5 pt-3   (no bottom padding)
close  : absolute right-2 top-2 inline-flex min-h-11 min-w-11 items-center justify-center
         rounded-lg text-fg-dim hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent
```

Root without padding so that a sheet the height of the screen still starts at y=0.
`max-h-dvh` + `min-h-0` + `flex-1 overflow-y-auto` is the only pattern that caps
height on phones while still leaving a scroll area. All values are stock
utilities; the only arbitrary value is
`pb-[max(0.75rem,env(safe-area-inset-bottom))]`, which
`scripts/check-tailwind-arbitrary.mjs` allows.

### One variant

There is no `center` variant and no full-screen variant. At 402x874 a centered
dialog pushes the footer into the home indicator area, and once the iOS keyboard
opens the confirm button is covered with no scroll container to rescue it.
Full-screen is a page, not a dialog (see the list below).

### Behavior

| Behavior | Implementation |
|---|---|
| Focus trap + restore | `useFocusTrap(sheetRef)` from `legacy/hooks/` |
| Escape | `useEscapeKey(onClose, dismissible)`; the global stack in the hook ensures only the topmost overlay wins, and `dismissible: false` detaches the listener |
| Tap scrim | `pointerdown` records whether the gesture started on the scrim; a click only closes if it started and ended on the scrim, so a drag-select from the body does not close the sheet |
| Body scroll lock | Module counter: the first overlay sets `body` to `position: fixed`, `top: -scrollY`, `width: 100%`, `overflow: hidden`; the last overlay restores the previous style and `scrollTo` the old position. `overflow: hidden` alone is not respected by iOS |
| Safe area | `pb-[max(0.75rem,env(safe-area-inset-bottom))]` is applied once on the sheet, not on the footer. Footerless sheets (#4, #11, #15) also stop above the home indicator; the footer must not repeat that padding |
| Keyboard clamp + lift | `useEffect` reads `window.visualViewport` (feature-detected) on resize/scroll: it writes inline `maxHeight = viewport.height - 16` and `marginBottom = max(0, innerHeight - viewport.height - offsetTop)`, then removes both on unmount. The margin lifts the sheet by the width of the area the keyboard covers, because the iOS layout viewport does not shrink with it; on desktop/Android the gap is 0 so nothing changes. This is a layout approximation until it is checked on a device |
| Semantics | `role="dialog"`, `aria-modal="true"`, `aria-labelledby` from `<h2 id>` (or `labelledBy`); ✕ is a 44px target with a label from `common.close` |
| Non-dismissible | When `dismissible` is false, ✕ is not rendered at all, not rendered disabled |

### What stays outside the primitive

| Surface | Reason |
|---|---|
| ActionsMenu (#14), account menu in HomeLayout (#16) | `role="menu"`, non-modal, must not scroll-lock or trap (tabbing out of that menu is legitimate), and must stay close to the trigger |
| ConfirmBars (#13), discard confirm scoreboard (#20) | Not dialogs: they have no open/close cycle, deliberately do not cover the screen, and their height is compensated by the content behind them. The only thing to add is Esc and `aria-live` |
| Tooltip `AnnotatedPlayerName` (#17) | Has no dismissal, `pointer-events-none` |
| Toast `ErrorBanner` (#18) | `role="alert"`, has no open/close lifecycle |
| Scoreboard surface (#19) | Not a dialog: a rotated landscape surface, score tap zones, no title, no scrim, no scroll lock |
| SummaryModal mode `standalone` (#10) | A page, not an overlay; only the non-standalone path uses the primitive |

Correction note: the audit recipe put the safe-area padding on the footer. The
mockup shows that a sheet without a footer (#4, #11, #15) must also stop above the
home indicator, so the primitive owns that padding once on the sheet container.
That is why the footer no longer carries `pb-[max(...)]`.

## Accessibility (Mobile PWA)

| Rule | Implementation |
|------|---------------|
| Focus rings | `focus-visible:ring-2` (NOT `focus:ring`) — no tap flash |
| Touch targets | ≥44px for interactive elements |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` |
| Screen readers | `aria-label` on icon buttons, `role="dialog"` on modals |
| Error text | `role="alert"` only. Adding `aria-live` on top is redundant and is documented as wrong in `legacy/components/ErrorBanner.tsx` |
| Keyboard nav | `role="button" tabIndex={0}` on score tap zones |
| Menu | `role="menu"` / `role="menuitem"` on ActionsMenu |

## File Locations

Paths are relative to `apps/web/`:

| Resource | Path |
|----------|------|
| CSS tokens (`@theme`) | `src/index.css` |
| Tier config | `src/config/tiers.ts` |
| Canvas config | `src/config/canvas.ts` |
| Generator config | `src/config/generator.ts` |
| Achievement config | `src/config/achievements.ts` |
