# E2E regression (T-072)

Playwright drives a real API, a disposable database and the OIDC stub. Nothing
here is mocked: the browser logs in through `tools/oidc-stub`, loads the built
bundle from `vite preview`, and talks to the Nim server through the same
same-origin `/api` path production uses.

```
./task e2e                     # a11y + visual + compatibility
./task e2e --update-snapshots  # rewrite the visual baseline on purpose
E2E_VISUAL=0 ./task e2e        # everything except the pixel comparison
```

The task resets `bm2_e2e`, migrates and seeds it, then starts three servers:

| What | Port | Notes |
|---|---|---|
| API | 18093 | `MAJADU_E2E_API_PORT` |
| OIDC stub | 19081 | `MAJADU_E2E_STUB_PORT` |
| Web preview | 5173 | `MAJADU_E2E_WEB_PORT`; must match the seeded `security.allowed_origins` |

## What is asserted

- **A11y** (`a11y.spec.ts`): axe with the WCAG 2.0/2.1 A+AA tags on every route
  in `visual.routes.ts` plus the spectator share page (`/s/:code`), expecting
  zero violations.
- **Visual** (`visual.spec.ts`): one full-page screenshot per route with
  `maxDiffPixels: 0`. Snapshots live in `__screenshots__/` and are part of the
  review, never regenerated silently.
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
It writes `e2e/.state.json`, which specs read; the file is ignored by git.

## What CI runs

The snapshots are recorded per platform (`{platform}` in the snapshot path) and
the checked-in set is Darwin. The GitHub runner has no Linux baseline, so the
workflow sets `E2E_VISUAL=0`: the a11y, navigation, write and compatibility
assertions all run, the pixel comparison is skipped. Recording the Linux set is
a deliberate `--update-snapshots` run on Linux, not something CI should do.

The job provisions PostgreSQL and calls `./task e2e` itself, so the API, the
OIDC stub and the preview server come from the same script a laptop uses. It is
also the only job that installs every pin in `deps.lock` — Nim packages, pnpm,
the browser builds and the coverage tools — so it runs `./task deps-check`
before the suite.
