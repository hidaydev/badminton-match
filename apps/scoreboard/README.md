# MAJADU Score

Courtside scoreboard installed as a PWA on the tablet or phone that runs the
match. Two halves, tap to score, a minus per half, reset, swap, fullscreen and
a text export of the match.

## Install

Both platforms install from the browser; there is no app store listing.

- **iOS / iPadOS (Safari).** Open the site, tap Share, then "Add to Home Screen".
  The in-app sheet shows the same steps on the first visit.
- **Android (Chrome).** Open the site and accept the install prompt, or use the
  browser menu and "Install app".

The installed app is landscape-only (manifest `orientation: landscape`); a
browser tab falls back to a CSS rotation when held in portrait. Open it once
before the tournament: the first visit has to download the shell before the app
works without a network.

## Offline

The built service worker precaches the app shell and its images. After one
successful load (and a reload, so the worker controls the page), the app opens,
scores and keeps score with no network. The install sheet only claims "Works
offline" once a worker controls the page, and an offline badge appears in the
board's corner when `navigator.onLine` is false.

Scores live in `localStorage` on the device (`score-red`, `score-blue`,
`name-red`, `name-blue`), and the app asks for persistent storage on the first
nonzero score. If the browser blocks storage the board still scores in memory
and shows "Scores are not being saved on this device". Use the export control
before handing the device to someone else: the export copies a JSON snapshot of
those four keys to the share sheet or clipboard.

One device writes at a time. A second tab or installed copy takes a Web Lock,
finds it held, and shows "Another window is keeping score" with its controls
disabled; it follows the first window through `storage` events.

## Deploy

The Vercel project is `majadu-score`, built from the repository root so the
pnpm workspace resolves:

```sh
pnpm install --frozen-lockfile
pnpm --filter majadu-score build
```

`apps/scoreboard/vercel.json` carries those commands plus the security headers
and the cache policy; `scripts/check-headers.mjs` fails the build when the file
drifts. The project's default domain is <https://majadu-score.vercel.app>; a
custom domain configured in Vercel replaces it without a code change. The
`main` branch deploys production (see `docs/ops/rc.md`).

## Known limit: iOS launch screen

iOS ignores the manifest colours for the launch splash and the app does not ship
per-device `apple-touch-startup-image` files, so an installed copy may flash
white for a moment before the dark board appears. This is accepted: the launch
image matrix has to be regenerated for every device size, the flash does not
affect scoring, and the app is opened once per tournament day. Revisit if the
launch becomes part of the field workflow.
