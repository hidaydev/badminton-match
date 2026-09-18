# Majadu App — Design System

> Formalized and adopted across the codebase. Last updated: 2026-09-19.

## Typography

| Role | Font | Weight | Tailwind | Usage |
|------|------|--------|----------|-------|
| Body | IBM Plex Sans | 400, 500, 600, 700 | `font-sans` | All UI text |
| Monospace | IBM Plex Mono | 400, 500 | `font-mono` | Labels, metadata, timestamps |
| Decorative | Granesta + Edosz | — | — | Instagram canvas date overlay only |

Loaded via Google Fonts (`display=swap`). Body uses `var(--font-sans)`.

## Color Tokens (Tailwind v4 `@theme`)

> These are the actual tokens used in components. Defined in the `@theme` block of
> `apps/web/src/index.css`. Contrast ratios dihitung terhadap `--color-ground`.

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
| `--color-accent-alt` | `#e3b341` | `text-accent-alt` | Interactive, links (kini sama dengan `accent`) |

### Status
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-success` | `#43a57d` | `text-success` | Positive states |
| `--color-error` | `#d65a5a` | `text-error` | Errors, destructive |
| `--color-warning` | `#e3b341` | `text-warning` | Warnings (sama dengan `accent`) |
| `--color-info` | `#5b8fbd` | `text-info` | Informational |

## Token Usage in Components

Migrasi ke semantic token belum 100%; sebagian komponen masih memakai kelas palet mentah
(`slate-*`, `indigo-*`). Padanan yang dituju:

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

| Value | Tailwind | Usage |
|-------|----------|-------|
| `1rem` | `rounded-2xl` / `p-4` | Cards |
| `0.75rem` | `rounded-xl` | Buttons |
| `0.5rem` | `rounded-lg` | Chips, inputs |
| `1.5rem` | `gap-6` | Section gaps |

## Component Patterns

Components follow the semantic token system. Key patterns:

- **Cards** use `bg-surface border border-border-subtle rounded-2xl p-4`
- **Chips** use `bg-elevated border border-border rounded-lg` with variant colors
- **Badges** use inline styling with status colors (`success`, `error`, `warning`, `info`)
- **Empty states** use centered layout with icon + title + description

## Button Variants (inline)

| Variant | Classes |
|---------|---------|
| Primary | `bg-indigo-600 hover:bg-indigo-500 text-white font-semibold rounded-xl` |
| Secondary | `border-2 border-dashed border-border hover:border-accent-alt text-fg-dim` |
| Ghost | `text-fg-dim hover:text-white hover:bg-elevated` |
| Danger | `text-error hover:text-red-300` or `bg-red-600 text-white` |
| Icon-only | `p-2 rounded-lg text-fg-dim hover:text-white` (≥44px touch) |

## Form Patterns

```tsx
// Input
className="bg-elevated border border-border rounded-lg px-3 py-1.5 text-sm text-white
  placeholder-slate-500 focus:outline-none focus:border-indigo-500
  focus-visible:ring-2 focus-visible:ring-indigo-500/50
  disabled:opacity-40 disabled:cursor-not-allowed h-9"

// Select
className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white
  focus:outline-none focus:border-indigo-500
  focus-visible:ring-2 focus-visible:ring-indigo-500/50
  cursor-pointer h-9"
```

## Accessibility (Mobile PWA)

| Rule | Implementation |
|------|---------------|
| Focus rings | `focus-visible:ring-2` (NOT `focus:ring`) — no tap flash |
| Touch targets | ≥44px for interactive elements |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` |
| Screen readers | `aria-label` on icon buttons, `role="dialog"` on modals |
| Error toast | `role="alert" aria-live="polite"` |
| Keyboard nav | `role="button" tabIndex={0}` on score tap zones |
| Menu | `role="menu"` / `role="menuitem"` on ActionsMenu |

## File Locations

Paths relatif terhadap `apps/web/`:

| Resource | Path |
|----------|------|
| CSS tokens (`@theme`) | `src/index.css` |
| Tier config | `src/config/tiers.ts` |
| Canvas config | `src/config/canvas.ts` |
| Generator config | `src/config/generator.ts` |
| Achievement config | `src/config/achievements.ts` |
