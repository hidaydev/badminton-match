# Majadu App — Design System

Version: 3.0.0
Last reviewed: 2026-11-27

> Formalized and adopted across the codebase. `./task docs-check` fails when
> either line above goes missing or the review date goes stale.

Sections marked **Batch B** record decision D-8 in the UI/UX audit backlog,
approved 2026-11-27. They are the contract the `feat/p1-visual-system` build is reviewed
against: where the code still shows the old recipe, the code is what moves, not
this document. Every Batch B rule is stated so a reviewer can grep the tree for
it.

## Versioning and review

Two lines at the top of this file are the contract with the gate:

- `Version:` is a semantic version of the documented contract, not of the app.
  Bump the minor when a token, a component prop or a recipe changes; bump the
  major when an existing recipe is replaced, so a reader can tell an additive
  change from a breaking one.
- `Last reviewed:` is the date a person read this whole file against the code.
  A review that finds nothing still bumps the date, because the point is when
  someone last looked.

`task.d/docs-check.sh` reads both. It fails when either line is missing, when
the version is not `X.Y.Z`, when the date is not `YYYY-MM-DD` or lies in the
future, and when the review is more than 90 days old. The limit is deliberate:
a document nobody has opened for a quarter is describing a codebase that has
moved, and a red build is a better reminder than a note in a calendar.

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

The steps are declared in `@theme` (`--text-*`). Two of them sit below `text-xs`:
`text-2xs` (11px) is the floor for body copy, and `text-meta` (10px) is the smaller
tracked-label token, used only by `label-meta` and never for data.

| Level | Token | Classes | Usage |
|-------|-------|---------|-------|
| Page Title | `--text-lg` / `--text-xl` | `text-lg font-bold sm:text-xl` | The one `h1` recipe, owned by `PageHeader` |
| Section Title | `--text-sm` | `text-sm font-semibold` | Section `h2` |
| Body | `--text-sm` | `text-sm text-fg-dim` | Descriptions |
| Label | `--text-xs` | `text-xs text-fg-dim` | Form labels |
| Meta | `--text-meta` (10px) | `text-meta font-mono label-meta` | Single tracked label |
| Detail | `--text-2xs` (11px) | `text-2xs` | Compact data, never below |

### Page title — Batch B

One recipe, in `PageHeader` (`src/components/PageHeader.tsx`):
`text-lg font-bold text-fg sm:text-xl`. No page spells an `h1` class of its own.

- A screen that draws its own title outside `PageHeader`, such as the session
  sheet's header, repeats that exact step (`text-lg font-bold sm:text-xl`). A
  screen at 16px/400 or `text-xl sm:text-2xl` is a defect of this rule.
- `EmptyState` used as a page heading keeps `titleClassName` on the same step,
  so the tallest text on the screen is the same size whether or not data landed.
- The old guidance `text-xl sm:text-2xl` is retired. Any remaining occurrence in
  `apps/web/src` is drift, not a variant.

Checkable: `grep -rn 'text-xl sm:text-2xl' apps/web/src` returns only stat
numbers and the scoreboard, never a page or sheet heading.

### Type floor — Batch B

`text-2xs` (11px) is the floor for body copy; `text-meta` (10px) is the only
token allowed below it, and only for a tracked label with `label-meta`.

- Write `text-2xs` and `text-meta`, never `text-[11px]` or `text-[10px]`.
  Arbitrary sizes bypass the token and cannot be ratcheted by the gate.
- `text-meta` never carries data: no score, no count, no timestamp value. It
  titles a block; the value under it is at least `text-2xs`.
- Retired: the table row that taught `text-[10px] font-mono label-meta` as the
  Meta step. It was the instruction the 116 `text-[10px]` call sites followed.

Checkable: `grep -rn 'text-\[10px\]\|text-\[11px\]' apps/web/src` counts only
down. The count is a ratchet, the same way the raw-palette count is.

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
| `0.5rem` | Spacing | `p-2` / `gap-2` | Chip and icon padding; the gap inside one row |
| `0.75rem` | Spacing | `p-3` / `gap-3` | Row padding (`Card padding="sm"`); the gap between rows |
| `1rem` | Spacing | `p-4` | Card padding (`Card padding="md"`) |
| `2rem` | Spacing | `mt-8` | The gap between page sections |

| Radius | Token | Tailwind | Usage |
|--------|-------|----------|-------|
| `0.5rem` | `--radius-lg` | `rounded-lg` | Chips, inputs |
| `0.75rem` | `--radius-xl` | `rounded-xl` | Buttons, **list rows** |
| `1rem` | `--radius-2xl` | `rounded-2xl` | **Launcher tiles**, sheet and panel surfaces |

| Elevation | Token | Tailwind | Usage |
|-----------|-------|----------|-------|
| Raised | `--shadow-sm` | `shadow-sm` | Chips, badges |
| Panel | `--shadow-md` | `shadow-md` | Cards, menus |
| Sheet | `--shadow-lg` | `shadow-lg` | Overlays |

### Row and container recipes — Batch B

One row recipe and one tile recipe. A screen picks one; it does not restyle a
`Card` to look like the other.

| Site | Recipe | Where |
|------|--------|-------|
| List row | `Card radius="xl" padding="sm"` | Sessions, players, settings rows, standings rows |
| Launcher tile | `Card radius="2xl"` (the default) | Both Home grids |

- `Card` defaults stay `radius="2xl"` and `padding="none"`, so the tile recipe is
  written by leaving the radius out, not by passing `radius="2xl"`.
- A list row that passes `radius="2xl"` or a page that spells
  `rounded-xl border border-border-subtle bg-surface` is drift.
- `padding="sm"` is the row's inner padding (p-3); a row does not add its own
  `px-*`/`py-*` on top of it.

Checkable: a list row is a `Card` with `radius="xl"` and `padding="sm"` in the
same opening tag; a Home launcher tile has no `radius` prop.

### Section rhythm — Batch B

Three gaps, one each per level. The owner's word for the old screens was
"spaciness", meaning there was no scale at all.

| Level | Class | Contract |
|-------|-------|----------|
| Inside a row | `gap-2` | Icon to label, label to value, chip to chip in one row |
| Between rows | `gap-3` | The column of rows, the column of cards |
| Between page sections | `mt-8` | One section of a page to the next |

- A page's first section does not open with `mt-*`; the page body's own top
  padding is that gap. `SettingsPage.tsx`'s first `mt-6` becomes `mt-8` so the
  first section matches the rest.
- `mt-6` and `mt-5` are not section gaps. A page that needs a different gap has
  a layout reason and records it here.
- `gap-2`/`gap-3` inside a `Card` follow the same steps; `p-*` on the card is a
  separate decision from the gap between its children.

Checkable: `grep -rn 'mt-6' apps/web/src/pages apps/web/src/legacy/pages` only
matches inside a component that documents why, and `SettingsPage.tsx` has no
`<section className="mt-6">`.

## Utilities in `index.css` — Batch B

A class a component writes as if it were CSS has to exist in `index.css` as an
`@utility`. The set today: `focus-ring`, `hit44`, `disabled-dim`,
`disabled-dim-soft`, `disabled-dim-faint`, `disabled-dim-ghost`, `z-overlay`,
`z-toast`, `label-meta`, and `no-scrollbar`.

`no-scrollbar` is the case that made this a rule. `RankingsPage.tsx:114` puts it
on a horizontal chip row, and no rule ever produced it, so the row showed a
scrollbar on every platform that draws one. The name states the intent, so it is
defined rather than deleted:

```css
/* A row that scrolls sideways on purpose: the overflow stays reachable, the bar
   does not draw. */
@utility no-scrollbar {
  scrollbar-width: none;
  &::-webkit-scrollbar {
    display: none;
  }
}
```

The touch gate (`apps/web/scripts/check-touch-targets.mjs`) asserts against the
built stylesheet rather than the spelling: every marker a source uses has a rule
in the built CSS, and every class a `@majadu/*` package renders compiles. Adding
`no-scrollbar` to `index.css` puts it in that artefact, which is the only proof
the class is real. Deleting the class and its call site would also be correct;
leaving it undefined is not. A new invented class gets the same test: define it,
or remove the call site.

## Breakpoints and viewports

Breakpoints come from `@theme` in each app's entry CSS, not from Tailwind's
defaults. `apps/web/src/index.css` overrides two of them and leaves `lg` at the
framework default:

| Prefix | `apps/web` (`@theme`, `src/index.css`) | `apps/scoreboard` (no override) |
|--------|----------------------------------------|---------------------------------|
| `sm:`  | `--breakpoint-sm: 25rem` (400px)       | 40rem (640px)                   |
| `md:`  | `--breakpoint-md: 40rem` (640px)       | 48rem (768px)                   |
| `lg:`  | 64rem (1024px), framework default       | 64rem (1024px), framework default |

`apps/scoreboard/src/index.css` imports Tailwind and the design tokens but sets
no breakpoint token, so the same `sm:` and `md:` class covers a different width
there (640px and 768px). A screen that has to break at the same width in both
apps needs its own token or an explicit value.

Layout changes are written with those prefixes. The two-column forms use `md:`
(so they stack below 640px), the wider page column uses `md:`, and the settings
screen uses `lg:` (1024px). A new prefix, or a change to one of these values, is
a layout change and belongs in this file with the screen that needs it.

Breakpoint values are 400/640/1024 and stay there (checked 2026-11-27 against
`src/index.css` `@theme`). MAJ-18 was this table quoting 640/768/1024 while the
CSS set 400/640/1024; the table now states the CSS, and a reader can verify it
with `grep -n 'breakpoint' apps/web/src/index.css`.

Three viewports are compared: `iphone-17` (402x874, WebKit) and `poco-f5`
(393x873, Chromium) for the phones, and `desktop` (1440x900, Chromium) for the
admin screens. `pnpm check:e2e` runs the visual baseline on all three, and the
`desktop` project also runs the axe walk. Snapshots are recorded per platform in
`e2e/__screenshots__/{platform}/`; a changed screen is recorded on both
platforms before review.

## Choosing a primitive

The set is closed. A site that does not fit one of these is a defect in the
recipe, not a new exception.

| Job | Primitive | Import |
|---|---|---|
| An action with a label | `Button` | `components/Button` |
| Navigation styled as an action | `ButtonLink` | `components/Button` |
| An action whose label is an icon | `IconButton` | `components/Button` |
| The whole surface is the target | `Card` with `variant="interactive"` | `components/Card` |
| Filter or single-choice pill, any look | `Chip` | `components/Chip` |
| Tab strip, any look | `Tabs` | `components/Tabs` |
| Any text input, labelled | `Field` + `Input` | `components/Field` |

Decision order: navigation goes to `ButtonLink`, an icon-only control to
`IconButton`, a whole-row target to `Card interactive`, a filter to `Chip`, a tab
strip to `Tabs`, a text field to `Field` + `Input`, everything else to `Button`.

Two more rules hold at this level, both from decision D-8:

- **One chip, one tab strip.** `Chip` and `Tabs` each absorb the looks their
  screens used to hand-roll, as a `variant`. A page may pass `variant` and
  `size`; it may not pass a class string that reproduces either.
- **No hand-rolled text control.** A raw `<input>` outside `Input`, or a
  `<label>` wrapper outside `Field`, is a defect even when it looks right.

### Button variants

Five variants. Each has one job, and the class strings stay in
`src/components/Button.tsx`.

| Variant | Tokens | Use when | Never |
|---|---|---|---|
| `primary` | `bg-accent`, `text-ground`, `font-semibold` | The single forward action of the screen or of one card | Twice in the same card, or next to another `primary` |
| `secondary` | `border-border`, `text-fg`, hover on `bg-elevated` | A real alternative next to a primary: cancel, retry, back, paging | As a decorative twin of primary when the action is the only one |
| `danger` | `border-border`, `text-error`, hover on `bg-elevated` | An action that destroys or overwrites data | A reversible action, or a neutral dismiss |
| `ghost` | `text-fg-dim`, no border, underline on hover | Low-emphasis inline action inside a card, row or block of text | As a row's primary action |
| `dashed` | dashed `border-border`, `text-fg-dim`, hover border `accent` | An empty slot that adds an item (player, pair, fixed match) | Anywhere the slot is already filled |

### Sizes

Two sizes, both 44px tall (`min-h-11`). `sm` narrows padding and type; it does not
shrink the tap target.

| Size | Padding | Type | Use |
|---|---|---|---|
| `md` | `px-4` | `text-sm` | Page and card level actions |
| `sm` | `px-3` | `text-xs` | Inside a row, a table cell or a dense toolbar |

### States

Every variant ships these seven states. A variant that cannot show one of them is
not shipped.

| State | Contract | How it is produced |
|---|---|---|
| Default | Readable at WCAG AA on its surface | Variant tokens |
| Hover | Visible change with no layout shift | Filter or background change, never size |
| Focus-visible | 2px accent ring with offset, visible on dark and light surfaces | `focus-ring` utility |
| Active | Scale `0.99`, no ring change | Utility class |
| Disabled | 50% opacity, `cursor: not-allowed`, no active scale, no hover change | `disabled` attribute |
| Loading | `aria-busy="true"`, unchanged label, spinner, submit blocked | `loading` prop |
| Pressed / selected | `aria-pressed` or `aria-selected`, accent border plus accent ink | Toggle and chip only |

Rules that hold across every state:

- Real `<button>` or `<a>`; no `role="button"` on a `div`.
- `type="button"` is the default, so a button inside a form does not submit by surprise.
- No nested interactive elements. A `Card interactive` never contains a `Button`.
- Icon-only controls carry `aria-label` and never an empty label with a tooltip.
- Disabled is not used to hide a permission the user cannot see; an action the
  user may not take is absent or explained, not dimmed.
- Loading keeps the label. Replacing the label with "Loading..." makes the button
  change width and tells the user nothing about what is in flight.

## Component Catalogue

Every file in `apps/web/src/components` is listed here. A component is imported
by name (`import { Button } from '../components/Button'`); there is no barrel.
Class strings belong in the component, not in this document: the props table and
the examples are the contract. Choosing between the primitives is the section
above; this section is the reference for each one.

### Button

`src/components/Button.tsx` — the only button. `variant` (`primary` |
`secondary` | `danger` | `ghost` | `dashed`), `size` (`md` | `sm`), `loading`,
and every native button prop through `{...rest}` (`aria-label`, `id`, `form`,
`onBlur`).

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

### IconButton

Exported from `src/components/Button.tsx` — the icon-only action. Same variants
and sizes as `Button` (both 44px tall), a square box, and `label` is required
because it becomes the `aria-label`; `loading` swaps the icon for a spinner.

```tsx
<IconButton label={t('shell.back')} size="sm" onClick={() => navigate(-1)}>
  <Icon name="chevron-left" size={18} />
</IconButton>
```

Anti-example: a `×` button with a `title` and no `aria-label`.

### Icon

`src/components/Icon.tsx` — the one 24px stroke set, drawn in `currentColor`.
`name` is the glyph (`IconName`), `size` defaults to 20, and every `svg` prop
passes through. The glyph is `aria-hidden`, so an icon-only control takes its name
from `IconButton`'s `label`.

```tsx
<Icon name="chevron-right" size={18} />
```

Anti-example: a hand-written `<svg>` with its own `strokeWidth` in a page.

### Chip

`src/components/Chip.tsx` — the only chip, in every place a chip appears. It is
the filter and single-choice control on rankings, tournaments and anywhere else a
row of choices sits. `selected` is rendered as `aria-pressed` and as the accent
outline, so the state reaches a screen reader; `size` is `md` or `sm` and both
stay 44px tall through `hit44`.

| Prop | Type | Notes |
|---|---|---|
| `selected` | `boolean` | Rendered as `aria-pressed` plus the accent border and ink |
| `size` | `'md' \| 'sm'` | `md` is `px-3 text-xs`, `sm` is `px-2.5 text-2xs`; height is 44px in both |
| `variant` | `'outline' \| 'pill'` | **Batch B.** `outline` is the bordered chip above; `pill` is the filled, fully rounded look the rankings tier row and the tournament format row used to spell locally |
| `loading` | `boolean` | Keeps the label, swaps in a spinner, blocks a second press |

`variant="pill"` replaces three local class strings, not one: the rankings tier
row (`RankingsPage.tsx`), the tournament format row (`TournamentListPage.tsx`)
and the pill that both copied. A page that writes `rounded-full border px-2.5 py-1`
on a `<button>` is drift.

```tsx
<Chip selected={tier === t} onClick={() => setTier(t)}>{TIER_LABELS[t]}</Chip>
<Chip variant="pill" selected={format === f} onClick={() => setFormat(f)}>{f}</Chip>
```

Anti-examples: a `<button>` whose selected state is only a blue background; a
`rounded-full` pill with its own `border`/`bg` pair; a tier row at 26px whose
last chip is clipped with no scroll affordance (MAJ-10 — the row scrolls, the
chip keeps 44px, and the overflow is visible as a partial chip, never a cut
`border`).

### Card

`src/components/Card.tsx` — the panel container. `padding` is `none` (default),
`sm` (p-3), `md` (p-4) or `lg` (p-6); `radius` is `2xl` (default), `xl` or `lg`.
The three radii stay available on purpose, but the recipe picks one: **a list row
is `radius="xl" padding="sm"`; a launcher tile is `radius="2xl"`** (see *Row and
container recipes — Batch B*). `variant` is `panel` (default), `flush` or
`interactive`: `flush` adds `overflow-hidden` for children that draw their own
dividers, such as a list or a table. The remaining div props pass through.
`CARD_RECIPE` is exported for the one component that has to spell the recipe on a
`details`. `variant="interactive"` is the whole-surface target: it adds the hover
and press affordances and takes `as` so the card is a real `button` (or a link)
instead of a clickable div.

```tsx
<Card radius="xl" padding="sm">row content</Card>
<Card padding="md" role="group" aria-label="Danger zone">...</Card>
<Card as="button" variant="interactive" onClick={open}>Sunday draft</Card>
```

Anti-example: `rounded-2xl border border-border-subtle bg-surface` in a page, or
a list row at `radius="2xl"`.

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
recipes, for every text field in the app (Batch B, decision D-8).

```tsx
<Field label="Aliases" hint="Comma separated"><Input value={aliases} /></Field>
```

Anti-example: a `<label>` wrapper plus a hand styled `<select>` and a hint with
no id.

The rule is absolute: a text field is `Field` + `Input`, and the 14 duplicated
control class strings that spelled `bg-elevated border border-border rounded-xl
px-3 py-3` by hand are deleted. A raw `<input>` in a page or a legacy component
is drift, even when it looks identical today, because the next change to the
input recipe would skip it.

Checkable: `grep -rn '<input' apps/web/src` matches only
`src/components/Field.tsx`, `src/components/Checkbox.tsx` and `src/components/Radio.tsx`.

One height for one control: every input, select and button that stands in a row
is at least 44px tall. The three heights MAJ-14 measured come from a hand-rolled
input, a `py-1` select and an unstyled control, and all three disappear with this
rule.

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

### Spinner

`src/components/Spinner.tsx` — the one spinner. `size` is the pixel box (12–16px
covers every inline use) and `className` passes through. It is decorative by
default; passing `label` turns it into a `role="status"` region marked
`aria-busy`, which is the only form assistive technology can act on.

```tsx
<Spinner size={14} label={t('app.saving')} />
```

Anti-example: an unlabelled spinner standing in for the only signal that a save is
in flight.

### PageHeader

`src/components/PageHeader.tsx` — the `h1` and optional subtitle every V2 page
opens with. It owns the page title recipe (`text-lg font-bold text-fg
sm:text-xl`) and the subtitle (`mt-1 text-sm text-fg-dim`); a page passes the
words and nothing else.

```tsx
<PageHeader title={t('players.title')} subtitle={t('players.subtitle')} />
```

Anti-example: a page-local `<h1 className="text-xl ...">`, or a heading in a
session sheet at `text-base font-normal` instead of the same step.

### Page

`src/components/Page.tsx` — the page column, exported as the `PAGE_COLUMN` class
string (`mx-auto w-full max-w-3xl px-4`). Every shell header and every page body
renders inside it, so the title, the back arrow and the content share one left
edge at every width. A page that needs a narrower column nests inside this one
instead of shrinking it.

```tsx
<main id="main" className={`${PAGE_COLUMN} py-4`}>...</main>
```

Anti-example: a page-local `max-w-` column that shifts the content edge.

### SkipLink

`src/components/SkipLink.tsx` — the first focusable element in a layout. It is
`sr-only` until focused, then appears above the header with `focus:z-overlay`, so a
keyboard user reaches `#main` without walking the header controls on every screen.
It takes no props; the label is `shell.skipToContent`.

```tsx
<SkipLink />
```

Anti-example: a shell with no way past its own header.

### RouteChange

`src/components/RouteChange.tsx` — the router-level scroll and focus handling,
mounted once in `App.tsx` and rendering nothing. A push starts at the top, a pop
restores the offset of that history entry, and the new screen is announced by
focusing `main h1` (or `main`, which is focusable for exactly this purpose). The
first render is a page load, so it leaves the browser's own restoration alone.

```tsx
<RouteChange />
```

Anti-example: a screen reader user left with no signal that the page changed.

### Overlay

`@majadu/scoreboard-ui` (re-exported at `src/components/Overlay.tsx`) — see the
Overlay section below.

### Tabs

`src/components/Tabs.tsx` — the only tab strip (Batch B, decision D-8). `items`
(`id`, `label`), `value`, `onChange`, `panelId`, `label`, optional `idPrefix`,
`className` and `tabClassName(active)`. It owns the roving tabindex and the
arrow/Home/End handling; the panel stays with the page.

| Prop | Type | Default | Notes |
|---|---|---|---|
| `items` | `readonly { id, label }[]` | required | Order is the reading order |
| `value` | `string` | required | The selected id |
| `onChange` | `(id: string) => void` | required | Called on click, arrow and Home/End |
| `panelId` | `string` | required | Each tab's `aria-controls` |
| `label` | `string` | required | The `tablist` accessible name |
| `idPrefix` | `string` | `panelId` | Prefix for `tabId`/`tabPanelId` |
| `variant` | `'pill' \| 'underline'` | `'pill'` | **Batch B.** `pill` is the filled gold block; `underline` is a text tab with an accent rule under the selected label |
| `className` | `string` | `flex gap-1` | The strip box |
| `tabClassName` | `(active: boolean) => string` | — | Escape hatch for spacing only. It is not a second look |

The variant is what the old `TabBar` was. That component and both of its test
files are deleted with this
version: a page that imported `TabBar` imports `Tabs` and passes
`variant="underline"`, and the required `idPrefix` those call sites passed is
still accepted.

The tournament screen's per-tab look moves into the variant, and `SummaryModal`
drops its `indigo` override for the default accent. A `tabClassName` that sets
`bg-indigo-*`, `text-indigo-*` or `border-indigo-*` is drift: the selected tab is
accent ink on every screen.

```tsx
<Tabs items={tabs} value={tab} onChange={setTab} panelId="panel" label="Sections" />
<Tabs items={tabs} value={tab} onChange={setTab} panelId="summary-panel"
  label="Views" idPrefix="summary-tabs" variant="underline" />
```

Anti-examples: a page-local `role="tablist"` with its own `querySelectorAll`; a
second tab component; an indigo selected state.

### StandingsTable

`src/components/StandingsTable.tsx` — the standings ledger (CMP-07), one row per
player or team. `layout` picks the shape: `ledger` (default, the five fixed
columns), `compact` (one line per pair inside a group card), `team` (points pills
over a member list), `record` (a stage line under the name) and `rank` (a drill-in
row with a movement arrow). `labels` carries the words, because the component holds
no literal of its own. Each layout keeps the classes of the surface it replaced, so
a pixel baseline does not move for a refactor.

```tsx
<StandingsTable layout="compact" rows={rows} labels={{ wins: 'W', losses: 'L' }} />
```

Anti-example: a sixth hand-built rank cell beside five others.

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

### Toast

`src/components/Toast.tsx` — the one toast (DS-24). It carries `role="alert"`
itself and floats fixed at the top centre; five pages import it.

The rule is **toast for a failed action, inline for a failed place**. A write that
failed with no element waiting for the message is a toast; a field, row, card or
list the user has to fix in place keeps its message inline, because a floating box
loses that association for a screen reader and for a sighted user on a phone. One
toast per screen: two failures at once are a screen that should show one of them
inline.

The z ladder is in `src/index.css`: 10 sticky row, 20 dropdown, 30 app header, 40
toast, 50 overlay. A toast sits **below** an open sheet, because an alert drawn
over a sheet that owns the focus trap cannot be focused or dismissed and it covers
the dialog; an alert raised while a sheet is open belongs inside the sheet as an
inline `ErrorText`.

| Prop | Type | Notes |
|---|---|---|
| `message` | `ReactNode` | The sentence the user reads |
| `onRetry` | `() => void` | Retries the failed action; rendered first |
| `action` | `ReactNode` | An action that is not a retry, e.g. "Load the server's version"; sits between retry and close |
| `onDismiss` | `() => void` | Renders the close button; without it the toast stays until the caller clears it |

Nothing here starts a timer: a failure is not an acknowledgement.

```tsx
{error !== null && <Toast message={error} onRetry={save} onDismiss={clear} />}
```

Anti-example: a toast for a field error, or two toasts stacked at once.

### Notification and status

`ErrorText`, `ClientOutdatedBanner` and `Toast` above are the three status
surfaces. A success message is a `role="status"` paragraph owned by the page.

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
| Micro labels | the `label-meta` utility: uppercase plus 0.05em tracking, the whole recipe; size and colour stay at the call site (DS-15) |
| Utility classes | every non-Tailwind class a component writes is a real `@utility` in `index.css`; a class that never became CSS is a defect, not a style |
| Touch targets | ≥44px for interactive elements, enforced by `apps/web/scripts/check-touch-targets.mjs` (`check:touch`) |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` |
| Screen readers | `aria-label` on icon buttons, `role="dialog"` on modals |
| Heading order | One `h1` per page (never the wordmark), `h2` per section, `h3` per card; axe `heading-order` runs on every `a11yRoutes` entry |
| Error text | `role="alert"` only. Adding `aria-live` on top is redundant; see `ErrorText` |
| Keyboard nav | a real `<button>` for every action, including the score tap zones; a `role="button"` wrapper around other controls nests interactive elements |
| Menu | `role="menu"` / `role="menuitem"` on ActionsMenu |

## Batch B review checklist

Each rule above with the check a reviewer runs. The batch is reviewable when all
nine pass; a failure names the recipe, not the screen.

| # | Rule | Check |
|---|------|-------|
| 1 | One page-title recipe | `grep -rn 'sm:text-2xl' apps/web/src/components apps/web/src/pages` returns nothing for a heading; `PageHeader.tsx` holds `text-lg font-bold` and `sm:text-xl` |
| 2 | Row and tile radii | a list row's `Card` carries `radius="xl"` with `padding="sm"`; a Home launcher tile passes no `radius` |
| 3 | One tab strip | `ls apps/web/src/components/TabBar.tsx` and both test files are gone; `Tabs` declares `variant?: 'pill' \| 'underline'`; `grep -rn 'indigo' apps/web/src/legacy/components/SummaryModal.tsx` returns nothing in the tab classes |
| 4 | One chip | `Chip` declares `variant?: 'outline' \| 'pill'`; `grep -rn 'rounded-full.*px-2.5' apps/web/src` hits no `<button>`; rankings and tournaments import `Chip` |
| 5 | Section rhythm | `SettingsPage.tsx` has no `<section className="mt-6">`; page sections use `mt-8`, row columns `gap-3`, rows `gap-2` |
| 6 | Type floor | `grep -rn 'text-\[10px\]\|text-\[11px\]' apps/web/src \| wc -l` only goes down; this file no longer teaches either literal |
| 7 | One text control | `grep -rn '<input' apps/web/src` matches only `Field.tsx`, `Checkbox.tsx`, `Radio.tsx` |
| 8 | Real utilities | every class outside Tailwind that a component writes appears as `@utility` in `index.css`; `no-scrollbar` is one of them |
| 9 | Breakpoints | `apps/web/src/index.css` sets `--breakpoint-sm: 25rem` and `--breakpoint-md: 40rem`; no other value in this file |

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
| `hitTarget.ts` | keep; the `hit44` utility is still used by dense rows | web |
