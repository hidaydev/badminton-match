# Accessibility status

What the automated gate proves, what it does not, and the two known defects that
are accepted for this release with a date.

## What CI measures

| Spec | Screens | What it asserts |
|---|---|---|
| `e2e/a11y.spec.ts` | the 20 routes in `a11yRoutes` (`visual.routes.ts` plus the spectator share page, 404, player ranking, wizard, privacy and terms) | axe with WCAG 2.0/2.1 A and AA tags, plus `heading-order`, reports zero violations |
| `e2e/a11y.public.spec.ts` | login, invitation (signed out), privacy, terms | the same rule set, without signing in |
| `e2e/keyboard.spec.ts` | the account menu and the install dialog | the menu opens, closes on Escape and activates an item with the keyboard only; the dialog takes focus, keeps Tab inside it, closes on Escape and returns focus to the trigger |
| `e2e/zoom.spec.ts` | the desktop project at a 720 CSS pixel viewport | 200 percent zoom has no horizontal scroll (Playwright has no zoom API, so the zoom is expressed as the layout width it produces) |

All runs use the two phone viewports in `e2e/browsers.ts`; the a11y, visual and
zoom specs also run on the 1440 pixel desktop project.

## What it does not prove

- **Keyboard coverage is one disclosure and one dialog.** Tab order across a
  full session flow, the wizard, and every form is not asserted.
- **Menu focus return is not asserted.** Escape closes the account menu, but the
  menu is a disclosure, not a dialog with a focus trap; A11Y-3 records that as
  accepted for 2.0.0. The dialog case asserts focus return for sheets that use
  the shared `Overlay`.
- **Screen-reader announcements** are not measured. `axe` cannot see them.
- **Assistive technology users** have no recorded manual pass.

## Closed since the last audit

| ID | Defect | Where | Proof |
|---|---|---|---|
| A11Y-1 | legacy toasts were not announced | `apps/web/src/legacy/components/ErrorBanner.tsx` | the container carries `role="alert"`; `rg -n 'role="alert"' apps/web/src/legacy/components/ErrorBanner.tsx` |
| A11Y-2 | the summary sheet had no dialog semantics | `apps/web/src/legacy/components/SummaryModal.tsx` | `role="dialog"`, `aria-modal` and a labelled tab list; `rg -n 'role="dialog"|aria-modal' apps/web/src/legacy/components/SummaryModal.tsx` |
| A11Y-4 | a forward Tab from the focused sheet left the dialog, because the trap only cycled when the last control was focused | `packages/scoreboard-ui/src/hooks/useFocusTrap.ts` | the trap handles the root in both directions; `e2e/keyboard.spec.ts` opens the install sheet with Enter and keeps six Tab presses inside it |

## Accepted risks

| ID | Defect | Where | Decision | Date |
|---|---|---|---|---|
| A11Y-3 | the account menu does not return focus to its trigger on Escape | `apps/web/src/legacy/components/HomeLayout.tsx` | accepted for 2.0.0; the trigger keeps focus because the menu never moves it | 2026-11-10 |

Each risk needs a date, an owner and a release by which it is closed or
re-accepted. The owner is the repository owner; the next review is the 2.1.0
release.
