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
| `--color-accent-alt` | `#6d9dc8` | `text-accent-alt` | Interactive, links |

### Status
Every role is a distinct hex. The ratio column is measured on `bg-elevated`,
the darkest surface a status label sits on (the danger button's hover state).
| Token | Hex | Tailwind class | Usage | Contrast on `elevated` |
|-------|-----|----------------|-------|------------------------|
| `--color-success` | `#43a57d` | `text-success` | Positive states | 5.31:1 |
| `--color-error` | `#d86f6a` | `text-error` | Errors, destructive | 4.92:1 |
| `--color-warning` | `#e0985c` | `text-warning` | Warnings | 6.77:1 |
| `--color-info` | `#5b8fbd` | `text-info` | Informational | 4.69:1 |

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

The steps are declared in `@theme` (`--text-*`). `text-2xs` (11px) is the floor:
nothing smaller is allowed, and data never uses a size below `text-xs` (12px).

| Level | Token | Classes | Usage |
|-------|-------|---------|-------|
| Page Title | `--text-2xl` / `--text-xl` | `text-xl sm:text-2xl font-bold` | Page `h1` |
| Section Title | `--text-sm` | `text-sm font-semibold` | Section `h2` |
| Body | `--text-sm` | `text-sm text-fg-dim` | Descriptions |
| Label | `--text-xs` | `text-xs text-fg-dim` | Form labels |
| Meta | `--text-meta` (10px) | `text-[10px] font-mono uppercase tracking-wider` | Single tracked label |
| Detail | `--text-2xs` (11px) | `text-[11px]` | Compact data, never below |

## Boolean Controls

`src/components/Checkbox.tsx` and `src/components/Radio.tsx` wrap the native inputs and
tint them with `accent-accent` (`accent-color: var(--color-accent)`), so the tick
or dot is brand gold instead of the UA blue. They carry the 20px box, the focus
ring and the disabled recipe; a call site passes only behaviour props.

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

## Component Catalogue

Every file in `apps/web/src/components` is listed here. A component is imported
by name (`import { Button } from '../components/Button'`); there is no barrel.
Class strings belong in the component, not in this document: the props table and
the two examples are the contract.

### Button

`src/components/Button.tsx` — the only button. `variant` (`primary` |
`secondary` | `danger`), `size` (`md` | `sm`), `loading`, and every native
button prop through `{...rest}` (`aria-label`, `id`, `form`, `onBlur`).

```tsx
<Button loading={saving} aria-label="Save settings" onClick={save}>Save</Button>
```

Anti-example: a raw `<button className="min-h-11 rounded-xl bg-accent ...">`.

### ButtonLink

Exported from `src/components/Button.tsx` — the same recipe rendered as a
router link. Use it for navigation that is styled as the primary action.

```tsx
<ButtonLink to="/owner/communities">Create a community</ButtonLink>
```

Anti-example: `<Link className="bg-accent ...">`.

### Card

`src/components/Card.tsx` — the panel container. `padding` is `none` (default),
`sm` (p-3) or `md` (p-4); the remaining div props pass through. `CARD_RECIPE`
is exported for the one component that has to spell the recipe on a `details`.

```tsx
<Card padding="md" role="group" aria-label="Danger zone">...</Card>
```

Anti-example: `rounded-2xl border border-border-subtle bg-surface` in a page.

### CollapsiblePanel

`src/components/CollapsiblePanel.tsx` — `details` + `summary` + the Card
recipe. `title`, optional `hint`, and any details prop (`open`, `id`, `ref`).

```tsx
<CollapsiblePanel title="Add player" hint="Admins only">...</CollapsiblePanel>
```

Anti-example: hand written `<details>` with a copied summary class.

### Field, Input and Select

`src/components/Field.tsx` — one named control with an optional hint. `Field`
generates (or accepts `id`) and points `htmlFor` at it, and appends the hint id
to the control's `aria-describedby`. `Input` and `Select` are the only control
recipes.

```tsx
<Field label="Aliases" hint="Comma separated"><Input value={aliases} /></Field>
```

Anti-example: a `<label>` wrapper plus a hand styled `<select>` and a hint with
no id.

### Checkbox and Radio

`src/components/Checkbox.tsx` and `src/components/Radio.tsx` — native inputs
tinted with `accent-accent`, with the 20px box, the `focus-ring` utility and the
disabled recipe. A call site passes only behaviour props.

```tsx
<Checkbox checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
```

Anti-example: `<input type="checkbox" className="h-4 w-4" />`.

### EmptyState

`src/components/EmptyState.tsx` — the centred empty block. `title`,
`description`, `action`, `icon`; `as` selects the title element and
`titleClassName` overrides its scale when the block is the page heading.

```tsx
<EmptyState title="No players yet" action={<Button>Add player</Button>} />
```

Anti-example: a bare `<p className="mt-2 text-sm text-fg-dim">` as the whole empty state.

### ErrorText

`src/components/ErrorText.tsx` — `role="alert"` and the error colour. No
`aria-live` on top: the role already implies it.

```tsx
{error !== null && <ErrorText className="mt-2">{error}</ErrorText>}
```

Anti-example: a `<p style={{ color: 'red' }}>`.

### LoadingState

`src/components/LoadingState.tsx` — placeholder rows with a screen-reader
`label`. `rows` defaults to 3.

```tsx
<LoadingState label={t('app.loading')} rows={2} />
```

Anti-example: a single "Loading..." line that shifts the layout when data lands.

### PageHeader

`src/components/PageHeader.tsx` — the `h1` and optional subtitle every V2 page
opens with.

```tsx
<PageHeader title={t('players.title')} subtitle={t('players.subtitle')} />
```

Anti-example: a page-local `<h1 className="text-xl ...">`.

### Overlay

`@majadu/scoreboard-ui` (re-exported at `src/components/Overlay.tsx`) — see the
Overlay section below.

### Tabs

`src/components/Tabs.tsx` — one WAI-ARIA tab strip. `items` (`id`, `label`),
`value`, `onChange`, `panelId`, `label`, optional `idPrefix`, `className` and
`tabClassName(active)`. It owns the roving tabindex and the arrow/Home/End
handling; the panel stays with the page.

```tsx
<Tabs items={tabs} value={tab} onChange={setTab} panelId="panel" label="Sections" />
```

Anti-example: a page-local `role="tablist"` with its own `querySelectorAll`.

### ClientOutdatedBanner

`src/components/ClientOutdatedBanner.tsx` — the 410 banner. `message` and
`actionLabel` arrive as props; it listens for the transport's outdated event.

```tsx
<ClientOutdatedBanner message={t('app.outdated')} actionLabel={t('app.outdated.action')} />
```

Anti-example: a banner that imports the i18n singleton from the components
directory.

### ConfirmButton

`src/components/ConfirmButton.tsx` — destructive action with an inline armed
state. `confirmLabel`, `onConfirm`, `variant`, `disabled`. Never use
`window.confirm`.

```tsx
<ConfirmButton confirmLabel="Really merge?" onConfirm={merge}>Merge</ConfirmButton>
```

Anti-example: `if (window.confirm(...)) merge()`.

### Notification and status

`ErrorText` and `ClientOutdatedBanner` above are the two status surfaces. A
success message is a `role="status"` paragraph owned by the page.

## Overlay (bottom sheet)

One primitive, one variant. The implementation lives in
`packages/scoreboard-ui/src/Overlay.tsx` and is re-exported from
`apps/web/src/components/Overlay.tsx`, so the web app and the scoreboard PWA
open the same sheet. Its tests are `Overlay.test.tsx` and the scoreboard's
`InstallModal.test.tsx` (which pins the focus trap).

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
| `focusKey` | `unknown` | - | Re-focus the sheet when a screen inside it changes and the focused button unmounts |
| `closeLabel` | `string` | `Close` | Accessible name of the ✕ button; the caller owns its translation |

### Layout

The sheet is a column: a fixed handle, header and footer around one scrollable
body (`min-h-0 flex-1 overflow-y-auto overscroll-contain`), with
`bottom: max(0.75rem, env(safe-area-inset-bottom))` applied once on the sheet.
The classes live in the component; this document no longer mirrors them.

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
| Focus rings | the `focus-ring` utility (defined once in `index.css`, NOT `focus:ring`) — no tap flash |
| Touch targets | ≥44px for interactive elements, enforced by `apps/web/scripts/check-touch-targets.mjs` (`check:touch`) |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` |
| Screen readers | `aria-label` on icon buttons, `role="dialog"` on modals |
| Heading order | One `h1` per page (never the wordmark), `h2` per section, `h3` per card; axe `heading-order` runs on every `a11yRoutes` entry |
| Error text | `role="alert"` only. Adding `aria-live` on top is redundant; see `ErrorText` |
| Keyboard nav | a real `<button>` for every action, including the score tap zones; a `role="button"` wrapper around other controls nests interactive elements |
| Menu | `role="menu"` / `role="menuitem"` on ActionsMenu |

## File Locations

Paths are relative to `apps/web/`:

| Resource | Path |
|----------|------|
| CSS tokens (`@theme`) | `src/index.css` |
| Tier config | `src/legacy/config/tiers.ts` |
| Canvas config | `src/legacy/config/canvas.ts` |
| Generator config | `src/legacy/config/generator.ts` |
| Achievement config | `src/legacy/config/achievements.ts` |
| Shared scoreboard UI | `packages/scoreboard-ui/src/` |
| Generated API client | `packages/web-client/src/api.ts` |

## Legacy component status

`src/legacy/components` is the v1 tree. It may import `src/components`, never
the other way (enforced by `no-restricted-imports`). Status by area; an owner
is the person who decides the next move.

| Area | Status | Owner |
|------|--------|-------|
| `scoreboard/` | migrated to `packages/scoreboard-ui`; the index is a re-export | web |
| `InstallModal.tsx` | keep on the shared Overlay | web |
| `UpdateBanner.tsx` | keep; web-only update prompt | web |
| `summary/` | migrate to the shared primitives (tabs, cards, standings) | web |
| `tournament/` | migrate after the standings table lands | web |
| `admin/` | migrate with the members and invites screens | web |
| `constraints/` | keep for the v1 session editor | web |
| `ratings/` | keep for the canvas and medal surfaces | web |
| `HomeLayout.tsx`, `SessionLayout.tsx` | keep until the shell moves | web |
| `ErrorBanner.tsx` | delete once every caller uses `ErrorText` | web |
| `hitTarget.ts` | keep; the `hit44` utility is still used by dense rows | web |
