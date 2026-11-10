# Panel mapping (DS-16)

Measured at `84709ac5`, branch `w5/ds`. One row per hand-built panel recipe.
Nothing here changes code.

## 1. How the count is taken

```sh
rg -o 'bg-surface border border-border-subtle' apps/web/src --glob '!**/Card.tsx' | wc -l
```

That returns **64** at this commit. Note what the pattern says: the hand-built
sites spell the three tokens in the order `bg-surface`, `border`,
`border-border-subtle`, while `CARD_RECIPE` in `Card.tsx` spells them
`rounded-2xl border border-border-subtle bg-surface`. The radius is the other
difference: `Card` fixes `rounded-2xl`, and only 3 of the 64 sites use it.

Files, descending: `RatingPlayerPage` 17, `CareerStats` 9, `HomePage` 6,
`NewTournamentWizard` 4, `TournamentListPage` 3, `TeamTournamentPage` 3,
`SessionListPage` 3, `RankingsPage` 2, `StandingsTab` 2, `PlayerStatsPanel` 2,
and one each in `AdminTournamentsPage`, `AdminSessionsPage`, `AdminRatingsPage`,
`TournamentPage`, `SetupPage`, `PlayersPage`, `NewTournamentPage`,
`TeamMatchCard`, `GroupAssignment`, `BracketTab`, `ValidationPanel`,
`AdminPageShell`, `AdminMenuGrid`.

## 2. Target variants

`Card` keeps one job: it is the container recipe and the only file allowed to
spell it. Three variants cover all 53 sites that should adopt it, plus two
props. A fourth variant would be a fourth excuse.

| Variant | What it adds to the recipe | Use when |
|---|---|---|
| `panel` (default) | nothing | A content block: a heading plus body, a stat group, a form section |
| `flush` | `overflow-hidden`, no padding | The children are rows that draw their own dividers: a list, a table, a rank ladder |
| `interactive` | hover border, active scale, `cursor-pointer`, renders as `button` or `Link` | The whole surface is the target and it contains no other control |

Props: `padding` (`none` | `sm` p-3 | `md` p-4 | `lg` p-6) and `radius`
(`2xl` default | `xl` | `lg`). `radius` exists because 61 of the 64 sites are
not 2xl, and adoption must not silently change every corner on the screen.

`interactive` requires `as`: `button` for an in-page action, `Link`/`to` for
navigation. It must not wrap a `Button`, a link or an input, because a nested
control inside a clickable surface is unreachable by keyboard.

## 3. The 64 sites

"Pad" and "Radius" are what the site has today, so the migration can be checked
one row at a time. `-` means the site sets no padding class.

| # | File | Line | Element | Today | Target | Note |
|---|---|---|---|---|---|---|
| 1 | `legacy/components/admin/AdminMenuGrid.tsx` | 28 | button | p-3.5, xl | `interactive` as button | Menu card |
| 2 | `legacy/components/admin/AdminPageShell.tsx` | 66 | div | px-3.5 py-2.5, xl | `panel`, sm, xl | Admin header strip |
| 3 | `legacy/components/constraints/ValidationPanel.tsx` | 75 | div | p-3, lg | `panel`, sm, lg | Per-player counts |
| 4 | `legacy/components/ratings/CareerStats.tsx` | 39 | div | p-3.5 / p-4, xl | `panel`, md, xl | Sessions history |
| 5 | `legacy/components/ratings/CareerStats.tsx` | 109 | div | p-3, xl | `panel`, sm, xl | Top partners |
| 6 | `legacy/components/ratings/CareerStats.tsx` | 120 | div | p-3, xl | `panel`, sm, xl | Top opponents |
| 7 | `legacy/components/ratings/CareerStats.tsx` | 137 | div | p-3, xl | `panel`, sm, xl | Stat block |
| 8 | `legacy/components/ratings/CareerStats.tsx` | 147 | div | p-3, xl | `panel`, sm, xl | Stat block |
| 9 | `legacy/components/ratings/CareerStats.tsx` | 159 | div | p-3, xl | `panel`, sm, xl | Stat block |
| 10 | `legacy/components/ratings/CareerStats.tsx` | 178 | div | p-3.5 / p-4, xl | `panel`, md, xl | Tournaments |
| 11 | `legacy/components/ratings/CareerStats.tsx` | 222 | div | p-3, xl | `panel`, sm, xl | Tournament partners |
| 12 | `legacy/components/ratings/CareerStats.tsx` | 233 | div | p-3, xl | `panel`, sm, xl | Tournament opponents |
| 13 | `legacy/components/summary/PlayerStatsPanel.tsx` | 22 | div | p-3, lg | `panel`, sm, lg | Stat tile |
| 14 | `legacy/components/summary/PlayerStatsPanel.tsx` | 97 | div | p-3, lg | `panel`, sm, lg | Stat tile |
| 15 | `legacy/components/tournament/BracketTab.tsx` | 356 | div | p-4, xl | `panel`, md, xl | Podium |
| 16 | `legacy/components/tournament/GroupAssignment.tsx` | 78 | div | -, xl | `flush`, xl | Group list |
| 17 | `legacy/components/tournament/StandingsTab.tsx` | 112 | div | p-4, xl | `panel`, md, xl | Podium |
| 18 | `legacy/components/tournament/StandingsTab.tsx` | 128 | div | -, xl | `flush`, xl | Standings table |
| 19 | `legacy/components/tournament/TeamMatchCard.tsx` | 52 | div | -, lg | `panel`, none, lg | Header plus body |
| 20 | `legacy/pages/HomePage.tsx` | 81 | div | p-3.5 / p-4, xl | `panel`, md, xl | `role="status"` draft loading row |
| 21 | `legacy/pages/HomePage.tsx` | 90 | div | p-3.5 / p-4, xl | `panel`, md, xl | `role="alert"` draft error, holds retry |
| 22 | `legacy/pages/HomePage.tsx` | 109 | button | p-3.5 / p-4, xl | `interactive` as button | Draft session card |
| 23 | `legacy/pages/HomePage.tsx` | 161 | button | p-3.5, xl | `interactive` as button | Menu item |
| 24 | `legacy/pages/HomePage.tsx` | 176 | button | p-3.5, xl | `interactive` as button | My stats |
| 25 | `legacy/pages/HomePage.tsx` | 193 | button | p-3.5, xl | `interactive` as button | Install app |
| 26 | `legacy/pages/NewTournamentPage.tsx` | 43 | button | p-4, xl | `interactive` as button | Format picker |
| 27 | `legacy/pages/NewTournamentWizard.tsx` | 166 | div | -, lg | `flush`, lg | Player list |
| 28 | `legacy/pages/NewTournamentWizard.tsx` | 225 | div | -, lg | `panel`, none, lg | Team block |
| 29 | `legacy/pages/NewTournamentWizard.tsx` | 371 | div | -, lg | `flush`, lg | Pair list |
| 30 | `legacy/pages/NewTournamentWizard.tsx` | 419 | div | -, lg | `flush`, lg | Group blocks |
| 31 | `legacy/pages/PlayersPage.tsx` | 109 | div | px-2.5 py-2, xl | `panel`, sm, xl | Editable player row, hover only, no click target |
| 32 | `legacy/pages/RankingsPage.tsx` | 150 | div | -, lg | **not Card** | Loading skeleton, `animate-pulse`, use `LoadingState` |
| 33 | `legacy/pages/RankingsPage.tsx` | 168 | ol | -, lg | `flush`, lg | Rank ladder |
| 34 | `legacy/pages/RatingPlayerPage.tsx` | 43 | div | -, 2xl | **not Card** | Skeleton block, use `LoadingState` |
| 35 | `legacy/pages/RatingPlayerPage.tsx` | 45 | div | -, xl | **not Card** | Skeleton tile, use `LoadingState` |
| 36 | `legacy/pages/RatingPlayerPage.tsx` | 46 | div | -, xl | **not Card** | Skeleton tile |
| 37 | `legacy/pages/RatingPlayerPage.tsx` | 47 | div | -, xl | **not Card** | Skeleton tile |
| 38 | `legacy/pages/RatingPlayerPage.tsx` | 49 | div | -, xl | **not Card** | Skeleton block |
| 39 | `legacy/pages/RatingPlayerPage.tsx` | 56 | div | p-6, xl | `panel`, lg, xl | Load failed; colour comes from `ErrorText` |
| 40 | `legacy/pages/RatingPlayerPage.tsx` | 103 | div | p-4 / p-5, 2xl | `panel`, lg, 2xl | Player header |
| 41 | `legacy/pages/RatingPlayerPage.tsx` | 181 | div | p-3, xl | `panel`, sm, xl | Stat tile |
| 42 | `legacy/pages/RatingPlayerPage.tsx` | 189 | div | p-3, xl | `panel`, sm, xl | Stat tile |
| 43 | `legacy/pages/RatingPlayerPage.tsx` | 201 | div | p-3, xl | `panel`, sm, xl | Stat tile |
| 44 | `legacy/pages/RatingPlayerPage.tsx` | 233 | div | p-6, xl | `panel`, lg, xl | Section block |
| 45 | `legacy/pages/RatingPlayerPage.tsx` | 245 | div | p-3, xl | `panel`, sm, xl | Match row; hover only, no click handler, so not `interactive` |
| 46 | `legacy/pages/RatingPlayerPage.tsx` | 345 | div | p-6, xl | `panel`, lg, xl | Section block |
| 47 | `legacy/pages/RatingPlayerPage.tsx` | 359 | div | p-6, xl | `panel`, lg, xl | Section block |
| 48 | `legacy/pages/RatingPlayerPage.tsx` | 364 | div | p-6, xl | `panel`, lg, xl | Section block |
| 49 | `legacy/pages/RatingPlayerPage.tsx` | 369 | div | p-6, xl | `panel`, lg, xl | Section block |
| 50 | `legacy/pages/RatingPlayerPage.tsx` | 376 | div | p-4 / p-5, 2xl | `panel`, md, 2xl | Achievements |
| 51 | `legacy/pages/SessionListPage.tsx` | 235 | div | -, xl | **not Card** | Skeleton list, `animate-pulse`, use `LoadingState` |
| 52 | `legacy/pages/SessionListPage.tsx` | 250 | div | p-8, xl | **not Card** | Empty block, use `EmptyState` |
| 53 | `legacy/pages/SessionListPage.tsx` | 283 | div | -, xl | `flush`, xl | Session list |
| 54 | `legacy/pages/SetupPage.tsx` | 296 | div | p-4, lg | `panel`, md, lg | Setup form block |
| 55 | `legacy/pages/TeamTournamentPage.tsx` | 297 | div | -, lg | `flush`, lg | Group table |
| 56 | `legacy/pages/TeamTournamentPage.tsx` | 340 | div | -, lg | `flush`, lg | Bracket rows |
| 57 | `legacy/pages/TeamTournamentPage.tsx` | 450 | div | px-4 py-3, lg | `panel`, sm, lg | Position photos |
| 58 | `legacy/pages/TournamentListPage.tsx` | 71 | div | -, xl | **not Card** | Skeleton list, `animate-pulse`, use `LoadingState` |
| 59 | `legacy/pages/TournamentListPage.tsx` | 86 | div | p-8, xl | **not Card** | Empty block, use `EmptyState` |
| 60 | `legacy/pages/TournamentListPage.tsx` | 92 | div | -, xl | `flush`, xl | Tournament list |
| 61 | `legacy/pages/TournamentPage.tsx` | 32 | div | -, xl | **not Card** | Skeleton group block, use `LoadingState` |
| 62 | `legacy/pages/admin/AdminRatingsPage.tsx` | 56 | div | -, xl | `flush`, xl | Rebuild log rows |
| 63 | `legacy/pages/admin/AdminSessionsPage.tsx` | 37 | div | -, xl | `flush`, xl | Session table |
| 64 | `legacy/pages/admin/AdminTournamentsPage.tsx` | 29 | div | -, xl | `flush`, xl | Tournament table |

## 4. Totals

| Target | Sites |
|---|---|
| `panel` | 34 |
| `flush` | 13 |
| `interactive` | 6 |
| Not `Card` | 11 |
| **Total** | **64** |

Of the 11 that cannot use `Card`, every one is a state placeholder, not a
container: 9 loading skeletons and 2 empty blocks. Adopting `Card` there would
give a placeholder a role it does not have. Seven of the nine skeletons are the
same three-row pulse the existing `LoadingState` already renders, and the two
empties are the centred block `EmptyState` already renders, so this mapping
feeds DS-18 and DS-17 rather than competing with them.

Radius today across the 64: `rounded-xl` 47, `rounded-lg` 14, `rounded-2xl` 3.
That is why `radius` is a prop: with `Card`'s fixed 2xl, adoption would move 47
corners by 4px and 14 by 8px, which is a visual change hidden inside a
refactor.

## 5. What this leaves to the owner

- Whether the design system normalises on one radius, or keeps three. The
  mapping works either way; normalising is a visual decision with a pixel diff
  on 63 screens, so it is not mine to take. Default: keep the three radii via
  the prop, adopt `Card` with no visual change, decide radius afterwards.
- `HomePage.tsx:81` and `:90` are a status row and an error row. They are
  containers today and stay containers, but they overlap DS-24 (no shared
  Alert). Default: map them to `panel` now and revisit when DS-24 lands.
- `PlayersPage.tsx:109` has a hover border with no click handler, so it reads
  as clickable and is not. That is a defect independent of DS-16. Default: keep
  it a `panel` and drop the hover border in the migration.
