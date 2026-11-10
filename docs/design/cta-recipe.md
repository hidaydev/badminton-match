# CTA recipe and raw button inventory (DS-03)

Measured at `84709ac5`, branch `w5/ds`. Nothing in this file changes code. It
turns DS-03 into a countable plan: every raw `<button>` outside `components/`
is classified, one recipe covers them, and the per-file list ends below the
DoD target of 40.

## 1. How the count is taken

```sh
rg -o '<button' apps/web/src --glob '!**/components/**' | wc -l
```

That command returns **90** at this commit. It is the audit's own check, and it
counts source text, not rendered controls. Two of the hits are string literals
in a test fixture (`i18n/hardcoded.test.ts:84` and `:95`) and three are real
`<button>` elements in a focus-trap harness (`legacy/hooks/useFocusTrap.test.tsx`).
So 90 grep hits are 85 UI sites plus 5 test-source hits.

Files, descending:

| File | Hits |
|---|---|
| `legacy/pages/PlayersPage.tsx` | 13 |
| `legacy/pages/SessionListPage.tsx` | 11 |
| `legacy/pages/InstagramPostPage.tsx` | 10 |
| `legacy/pages/NewTournamentWizard.tsx` | 9 |
| `legacy/pages/GeneratePage.tsx` | 7 |
| `legacy/pages/HomePage.tsx` | 6 |
| `legacy/pages/TeamTournamentPage.tsx` | 5 |
| `legacy/pages/SetupPage.tsx` | 4 |
| `legacy/pages/RankingsPage.tsx` | 4 |
| `legacy/pages/TournamentListPage.tsx` | 3 |
| `legacy/pages/SharedSessionPage.tsx` | 3 |
| `legacy/pages/RatingPlayerPage.tsx` | 3 |
| `legacy/hooks/useFocusTrap.test.tsx` | 3 |
| `legacy/pages/ConstraintsPage.tsx` | 2 |
| `i18n/hardcoded.test.ts` | 2 |
| `pages/SetupPage.tsx` | 1 |
| `legacy/pages/admin/AdminTournamentsPage.tsx` | 1 |
| `legacy/pages/admin/AdminRatingsPage.tsx` | 1 |
| `legacy/pages/NewTournamentPage.tsx` | 1 |
| `community/DirectoryList.tsx` | 1 |

## 2. Classification

Two buckets, as DS-03 asks, plus a third column for the sites that must stay
raw because a shared component would break them.

| Bucket | Sites | Meaning |
|---|---|---|
| Active player or staff flow | 85 | Reachable from a route in `apps/web/src/App.tsx` at this commit |
| Legacy or one-off | 5 | Test fixture text (2) and a focus-trap harness (3), never rendered to a user |
| Stays raw inside an active flow | 1 | The file-picker hotspot in `InstagramPostPage.tsx:446` |

The distinction that matters: **`legacy/` is not dead code.** Fourteen of the
sixteen routed screens under `/c/:slug` are still the v1 tree, including the
session setup wizard (`session/new`), the player wizard (`session/players`),
the generator (`session/generate`) and the public share page (`s/:sessionId`).
Deleting or freezing `legacy/` to close this finding would remove the flow real
players use today. The inventory is therefore a migration list, not a deletion
list.

## 3. The recipe

Five primitives, no sixth. A site that does not fit one of these is a defect in
the recipe, not a new exception.

| Job | Primitive | Import |
|---|---|---|
| An action with a label | `Button` | `components/Button` |
| Navigation styled as an action | `ButtonLink` | `components/Button` |
| An action whose label is an icon | `IconButton` | `components/Button` (to add) |
| The whole surface is the target | `Card` with `variant="interactive"` | `components/Card` |
| Filter or single-choice pill | `Chip` | `components/Chip` (to add) |
| Tab strip | `Tabs` | `components/Tabs` (exists) |

Decision order: navigation goes to `ButtonLink`, an icon-only control to
`IconButton`, a whole-row target to `Card interactive`, a filter to `Chip`, a
tab strip to `Tabs`, everything else to `Button`.

### 3.1 Button variants

Five variants. Each has one job, and the class strings stay in
`components/Button.tsx`, not here.

| Variant | Tokens | Use when | Never |
|---|---|---|---|
| `primary` | `bg-accent`, `text-ground`, `font-semibold` | The single forward action of the screen or of one card | Twice in the same card, or next to another `primary` |
| `secondary` | `border-border`, `text-fg`, hover on `bg-elevated` | A real alternative next to a primary: cancel, retry, back, paging | As a decorative twin of primary when the action is the only one |
| `danger` | `border-border`, `text-error`, hover on `bg-elevated` | An action that destroys or overwrites data | A reversible action, or a neutral dismiss |
| `ghost` | `text-fg-dim`, no border, underline on hover | Low-emphasis inline action inside a card, row or block of text | As a row's primary action |
| `dashed` | dashed `border-border`, `text-fg-dim`, hover border `accent` | An empty slot that adds an item (player, pair, fixed match) | Anywhere the slot is already filled |

### 3.2 Sizes

Two sizes, both 44px tall (`min-h-11`). `sm` narrows padding and type, it does
not shrink the tap target.

| Size | Padding | Type | Use |
|---|---|---|---|
| `md` | `px-4` | `text-sm` | Page and card level actions |
| `sm` | `px-3` | `text-xs` | Inside a row, a table cell or a dense toolbar |

### 3.3 States

Every variant ships these seven states. A variant that cannot show one of them
is not shipped.

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
- Loading keeps the label. Replacing the label with "Loading..." makes the
  button change width and tells the user nothing about what is in flight.

## 4. Per-file reduction list

"Replaces" names the primitive each site moves to. "Stays" is what remains raw
after the migration.

| File | Raw | Replaces | Stays |
|---|---|---|---|
| `legacy/pages/PlayersPage.tsx` | 13 | 3 `Button` (1 primary, 1 secondary, 1 ghost), 3 dashed add slots, 4 `IconButton`, 2 `Chip` tier filters, 1 `ButtonLink` | 0 |
| `legacy/pages/SessionListPage.tsx` | 11 | 9 `Button`, 1 `ButtonLink`, 1 `Card interactive` (session row) | 0 |
| `legacy/pages/InstagramPostPage.tsx` | 10 | 5 `Card interactive` (mode tiles and row), 4 `IconButton` | 1 (canvas hotspot at `:446`) |
| `legacy/pages/NewTournamentWizard.tsx` | 9 | 9 `Button` (6 primary, 2 secondary `sm`, 1 ghost `sm`) | 0 |
| `legacy/pages/GeneratePage.tsx` | 7 | 7 `Button` (1 primary, 1 secondary, 4 danger, 1 ghost) | 0 |
| `legacy/pages/HomePage.tsx` | 6 | 4 `Card interactive` (menu and draft cards), 1 `ButtonLink`, 1 `Button` | 0 |
| `legacy/pages/TeamTournamentPage.tsx` | 5 | 2 `Button`, 2 `IconButton`, 1 `Tabs` | 0 |
| `legacy/pages/SetupPage.tsx` | 4 | 3 `IconButton` (two steppers, one remove), 1 `Button` | 0 |
| `legacy/pages/RankingsPage.tsx` | 4 | 2 `Chip`, 1 `Card interactive` (rank row), 1 `Button` ghost | 0 |
| `legacy/pages/TournamentListPage.tsx` | 3 | 1 `ButtonLink`, 1 `Chip`, 1 `Card interactive` | 0 |
| `legacy/pages/SharedSessionPage.tsx` | 3 | 1 `IconButton`, 1 `Button`, 1 `ButtonLink` ghost | 0 |
| `legacy/pages/RatingPlayerPage.tsx` | 3 | 3 `Button` secondary | 0 |
| `legacy/hooks/useFocusTrap.test.tsx` | 3 | none, the harness tests focus order on primitive elements | 3 |
| `legacy/pages/ConstraintsPage.tsx` | 2 | 1 `Button` dashed, 1 `ButtonLink` | 0 |
| `i18n/hardcoded.test.ts` | 2 | none, string fixtures for the copy scanner | 2 |
| `pages/SetupPage.tsx` | 1 | 1 `IconButton` (back) | 0 |
| `legacy/pages/admin/AdminTournamentsPage.tsx` | 1 | 1 `ButtonLink` ghost | 0 |
| `legacy/pages/admin/AdminRatingsPage.tsx` | 1 | 1 `Button` secondary | 0 |
| `legacy/pages/NewTournamentPage.tsx` | 1 | 1 `Card interactive` | 0 |
| `community/DirectoryList.tsx` | 1 | 1 `Card interactive` | 0 |
| **Total** | **90** | **84 adopt a primitive** | **6** |

Totals by primitive: `Button` 42 (13 primary, 15 secondary, 4 danger, 6 ghost,
4 dashed), `IconButton` 15, `Card interactive` 14, `ButtonLink` 7, `Chip` 5,
`Tabs` 1. That is 84 sites, plus 1 hotspot and 5 test-source hits, which is the
90 the grep counts.

The DoD target is under 40. The full migration reaches **6**, and the six files
with six or more sites account for 56 of the 90, so migrating those six alone
leaves **34**, already under the target. Stage 1 is therefore: `PlayersPage`,
`SessionListPage`, `InstagramPostPage`, `NewTournamentWizard`, `GeneratePage`,
`HomePage`.

## 5. What this leaves to the owner

- `Chip` and `IconButton` do not exist yet. The recipe needs them created
  before four files can move, and creating a primitive is a design decision,
  not a refactor. Default: create both with the variants named in section 3.
- The accent tinted outline at `SessionListPage.tsx:162` (`border-accent/60`,
  `text-accent`) has no variant in the closed set. Default: it becomes
  `secondary`, losing the tint, because a second outlined-accent style is how
  the set grew to seven in the first place.
- The file-picker hotspot at `InstagramPostPage.tsx:446` covers the image and
  is positioned absolutely. A `Button` there would need `inset-0` and no
  padding. Default: keep it raw and exempt it, with an `aria-label` already
  present.
- Whether `legacy/` pages get migrated one by one or replaced wholesale by the
  V2 screens is a product call for Panji and the owner. This file only makes
  the site count countable either way.
