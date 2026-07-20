# Majadu App — Design System

> Formalized and adopted across the codebase. Last updated: 2026-07-20.

## Typography

| Role | Font | Weight | Tailwind | Usage |
|------|------|--------|----------|-------|
| Body | IBM Plex Sans | 400, 500, 600, 700 | `font-sans` | All UI text |
| Monospace | IBM Plex Mono | 400, 500 | `font-mono` | Labels, metadata, timestamps |
| Decorative | Granesta + Edosz | — | — | Instagram canvas date overlay only |

Loaded via Google Fonts (`display=swap`). Body uses `var(--font-sans)`.

## Color Tokens (Tailwind v4 `@theme`)

> These are the actual tokens used in components. Defined in `src/index.css` `@theme` block.

### Background
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-ground` | `#0f172a` | `bg-ground` | Page background |
| `--color-surface` | `#1e293b` | `bg-surface` | Cards, panels |
| `--color-elevated` | `#334155` | `bg-elevated` | Inner cards, inputs |

### Border
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-border` | `#475569` | `border-border` | Visible borders |
| `--color-border-subtle` | `#334155` | `border-border-subtle` | Dividers, card borders |

### Text (WCAG AA on `bg-ground`)
| Token | Hex | Tailwind class | Ratio |
|-------|-----|----------------|-------|
| `--color-fg` | `#f1f5f9` | `text-fg` | ~15.5:1 |
| `--color-fg-dim` | `#94a3b8` | `text-fg-dim` | ~7.1:1 |

### Accent
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-accent` | `#fbbf24` | `text-accent` | Brand, CTA, highlights |
| `--color-accent-alt` | `#818cf8` | `text-accent-alt` | Interactive, links |

### Status
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-success` | `#34d399` | `text-success` | Positive states |
| `--color-error` | `#f87171` | `text-error` | Errors, destructive |
| `--color-warning` | `#fbbf24` | `text-warning` | Warnings |
| `--color-info` | `#38bdf8` | `text-info` | Informational |

## Token Usage in Components

The semantic tokens are actively used across the codebase:

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

## Component Library (`src/components/ui/`)

### Card
```tsx
import { Card } from './ui'
<Card>Surface card</Card>
<Card variant="elevated">Elevated card</Card>
<Card variant="interactive">Clickable card</Card>
```

### Chip
```tsx
import { Chip } from './ui'
<Chip>Default</Chip>
<Chip variant="selected">Selected</Chip>
<Chip variant="success">Success</Chip>
```

### Badge
```tsx
import { Badge } from './ui'
<Badge variant="success">Won</Badge>
<Badge variant="error">Lost</Badge>
```

### EmptyState
```tsx
import { EmptyState } from './ui'
<EmptyState icon="🏸" title="No sessions" description="Create one" />
```

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

| Resource | Path |
|----------|------|
| CSS tokens (`@theme`) | `src/index.css` |
| JS tokens | `src/config/tokens.ts` |
| UI components | `src/components/ui/` |
| Barrel export | `src/components/ui/index.ts` |
| Tier config | `src/config/tiers.ts` |
