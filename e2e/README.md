# E2E regression (T-072)

Playwright drives a real API, a disposable database and the OIDC stub. Nothing
here is mocked: the browser logs in through `tools/oidc-stub`, loads the built
bundle from `vite preview`, and talks to the Nim server through the same
same-origin `/api` path production uses.

```
./task e2e                     # a11y + visual + compatibility
./task e2e --update-snapshots  # rewrite the visual baseline on purpose
```

The task resets `bm2_e2e`, migrates and seeds it, then starts three servers:

| What | Port | Notes |
|---|---|---|
| API | 18093 | `MAJADU_E2E_API_PORT` |
| OIDC stub | 19081 | `MAJADU_E2E_STUB_PORT` |
| Web preview | 5173 | `MAJADU_E2E_WEB_PORT`; must match the seeded `security.allowed_origins` |

## What is asserted

- **A11y** (`a11y.spec.ts`): axe with the WCAG 2.0/2.1 A+AA tags on every route
  in `visual.routes.ts`, expecting zero violations.
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
players, one session and one classic tournament drawn by `apps/web`'s own
`drawGroups`/`generateGroupMatches` — the same code the wizard uses, so the
fixture cannot drift from the rules. It writes `e2e/.state.json`, which specs
read; the file is ignored by git.
