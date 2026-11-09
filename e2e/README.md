# E2E regression (T-072)

Playwright drives a real API, a disposable database and the OIDC stub. Nothing
here is mocked: the browser logs in through `tools/oidc-stub`, loads the built
bundle from `vite preview`, and talks to the Nim server through the same
same-origin `/api` path production uses.

```
./task e2e                     # a11y + visual + compat + scoreboard
./task e2e --update-snapshots  # rewrite this platform's visual baseline
```

The task resets `bm2_e2e`, migrates and seeds it, then starts four servers:

| What | Port | Notes |
|---|---|---|
| API | 18093 | `MAJADU_E2E_API_PORT` |
| OIDC stub | 19081 | `MAJADU_E2E_STUB_PORT` |
| Web preview | 5173 | `MAJADU_E2E_WEB_PORT`; must match the seeded `security.allowed_origins` |
| Scoreboard preview | 4173 | `MAJADU_E2E_SCOREBOARD_PORT`; serves the built `apps/scoreboard` |

## What is asserted

- **A11y** (`a11y.spec.ts`): axe with the WCAG 2.0/2.1 A+AA tags on every route
  in `visual.routes.ts` plus the spectator share page (`/s/:code`), expecting
  zero violations.
- **A11y, public** (`a11y.public.spec.ts`): the same tags on the screens reachable
  without a session, which the signed-in sweep never sees: the login screen, the
  invitation error state, the privacy page and the terms page.
- **Keyboard** (`keyboard.spec.ts`): opens the account menu, closes it with
  Escape, tabs into it and activates a menu item without a pointer. The state of
  the known gaps is in `docs/ops/accessibility.md`.
- **Visual** (`visual.spec.ts`): one full-page screenshot per route with
  `maxDiffPixels: 0`. Snapshots live in `__screenshots__/{platform}/` and are
  part of the review, never regenerated silently.
- **Scoreboard** (`scoreboard.spec.ts`): loads the built scoreboard from its own
  preview, scores a point, goes offline, reloads from the service worker cache
  and scores again. It takes no screenshots, so it does not depend on the visual
  baseline.

Every spec waits for the screen's own data (`VisualRoute.ready`) instead of
`networkidle`, which never settles on a screen holding a WebSocket open. No spec
uses `test.skip`.
- **Compatibility** (`compat.spec.ts`): a request carrying an older
  `X-API-Version` gets `410 CLIENT_OUTDATED` and the shell shows the reload
  banner.

## Routes and browsers are lists, not assumptions

`visual.routes.ts` names every screen in the baseline, and `browsers.ts` names
the browsers. A page or browser joins the suite by an edit there, which shows up
in review.

The viewports are the two phones the app is used on, each on its real engine:
`iphone-17` (WebKit, 402×874, DPR 3) and `poco-f5` (Chromium, 393×873,
DPR 2.75). They differ in aspect ratio on purpose — 19.5:9 against 20:9 — so a
layout that only fits one of them fails. The baseline records today's rendering;
a layout fix changes snapshots on purpose.

`desktop` (Chromium, 1440×900) covers the `sm:`/`md:`/`lg:` branches an admin
uses at a laptop. It runs only `a11y.spec.ts`: the visual baseline is per
platform, so a new width would have to be recorded on both before the
comparison meant anything.

Firefox is not part of the suite. Its macOS build (revision 1555, pinned in
`deps.lock`) only starts with `CFFIXED_USER_HOME` pointed at an empty directory,
and the owner chose not to carry that workaround.

## Fixtures

`global-setup.ts` signs in through the stub, creates `e2e-club` with four
players, one session and one classic tournament. Its round robin and bracket
slots come from `apps/web/src/legacy/utils/tournament.ts`, the module the
screens use, so those cannot drift from the rules. The seeded group shuffle
lives in `e2e/draw.ts`: the wizard's copy lived with the classic tournament
files the legacy rewrite removed, and the fixture needs a stable seed anyway.
It writes `e2e/.state/run-<id>.json`, which specs read; the directory is ignored
by git. The name carries the run (or `E2E_RUN_ID`), so two runs on one machine do
not read each other's community ids.

## What CI runs

The snapshots are recorded per platform, in `e2e/__screenshots__/{platform}/`,
because glyph rasterisation differs between macOS and Linux and production is
Linux. Both sets are committed.

The checked-in Darwin set is what a developer records and reviews locally. The
Linux set was recorded on a Linux machine, reviewed and committed; CI never
records a baseline on its own. `e2e/__screenshots__/linux/` is part of the
repository, so a missing or different PNG fails every ref, and a run that finds
the directory missing fails instead of recording it. To change a baseline,
record it on the matching platform with `./task e2e --update-snapshots`, review
the PNGs and commit them with the change.

The job provisions PostgreSQL and calls `./task e2e` itself, so the API, the
OIDC stub and both previews come from the same script a laptop uses. It is also
the only job that installs every pin in `deps.lock` (Nim packages, pnpm, the
browser builds and the coverage tools), so it runs `./task deps-check` before
the suite.
