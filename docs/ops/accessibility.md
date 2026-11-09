# Accessibility status

What the automated gate proves, what it does not, and the two known defects that
are accepted for this release with a date.

## What CI measures

| Spec | Screens | What it asserts |
|---|---|---|
| `e2e/a11y.spec.ts` | the 12 routes in `visual.routes.ts` plus the spectator share page | axe with WCAG 2.0/2.1 A and AA tags, plus `heading-order`, reports zero violations |
| `e2e/a11y.public.spec.ts` | login, invitation (signed out), privacy, terms | the same rule set, without signing in |
| `e2e/keyboard.spec.ts` | the community shell and the account menu | the menu opens, closes on Escape and activates an item with the keyboard only |

All runs use the two phone viewports in `e2e/browsers.ts`, on WebKit and
Chromium. There is no desktop or tablet viewport.

## What it does not prove

- **Keyboard coverage is one disclosure.** Tab order across a full session flow,
  the wizard, and every form is not asserted.
- **Focus return is not asserted.** Escape closes the account menu, but the menu
  is a disclosure, not a dialog with a focus trap, and no spec checks where
  focus lands. This is accepted for 2.0.0 because no dialog on the measured
  routes relies on a focus trap.
- **Zoom and reflow** at 200 percent, and screen-reader announcements, are not
  measured. `axe` cannot see either.
- **Assistive technology users** have no recorded manual pass.

## Closed since the last audit

| ID | Defect | Where | Proof |
|---|---|---|---|
| A11Y-1 | legacy toasts were not announced | `apps/web/src/legacy/components/ErrorBanner.tsx` | the container carries `role="alert"`; `rg -n 'role="alert"' apps/web/src/legacy/components/ErrorBanner.tsx` |
| A11Y-2 | the summary sheet had no dialog semantics | `apps/web/src/legacy/components/SummaryModal.tsx` | `role="dialog"`, `aria-modal` and a labelled tab list; `rg -n 'role="dialog"|aria-modal' apps/web/src/legacy/components/SummaryModal.tsx` |

## Accepted risks

| ID | Defect | Where | Decision | Date |
|---|---|---|---|---|
| A11Y-3 | the account menu does not return focus to its trigger on Escape | `apps/web/src/legacy/components/HomeLayout.tsx` | accepted for 2.0.0; the trigger keeps focus because the menu never moves it | 2026-11-10 |

Each risk needs a date, an owner and a release by which it is closed or
re-accepted. The owner is the repository owner; the next review is the 2.1.0
release.
