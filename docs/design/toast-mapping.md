# Toast surface and the `role="alert"` sites (DS-24)

Measured at `d7ddfcff`. `rg -c 'role="alert"' apps/web/src` returns 17 lines:
15 declarations in JSX plus two mentions inside doc comments (`ErrorText.tsx`,
`ErrorBanner.tsx`). This file records which of them moved to `Toast` and why the
rest stayed inline.

A toast is the right surface when the failure belongs to an *action* and not to
a *place*: it is transient, page-level, and nothing on the page is waiting for
it. Anything attached to a field, a row, a card or a list that the user has to
fix in place stays inline, because a floating box loses that association for a
screen reader and for a sighted user on a phone.

## Moved to `components/Toast.tsx`

| Site | Why it is a toast |
|---|---|
| `legacy/pages/TournamentPage.tsx` save error | A write that failed with no element to sit next to; it is not part of the bracket. |
| `legacy/pages/TeamTournamentPage.tsx` publish error | Same, for the match-day publish action. |
| `legacy/pages/TeamTournamentPage.tsx` overlay error | Same, for the canvas export. |
| `legacy/pages/GeneratePage.tsx` save/publish error | The generate result is still on screen and valid; only the write failed, so the message must not replace the panel. |

The previous `legacy/components/ErrorBanner.tsx` was already a toast in
everything but name (fixed, top-centre, `z-60`, no timer of its own), so it is
deleted and its four call sites now render `Toast` directly. The `z-60` it
carried is the named step `z-toast` in `src/index.css`.

## Stays inline, with the reason

| Site | Reason it is not a toast |
|---|---|
| `components/ErrorText.tsx` | A field's error text and the `aria-describedby` target of that field; moving it away from the input breaks the association. |
| `components/ClientOutdatedBanner.tsx` | A persistent shell banner that pushes the page down and carries the reload action; it is a state, not an event. |
| `pages/SharedSessionPage.tsx:189` | "not found" is the page's own content state, not a failed action. |
| `pages/SharedSessionPage.tsx:194` | The read that fills the page failed, so the message replaces the content it would have shown. |
| `legacy/pages/SessionListPage.tsx:132` | The publish confirmation the user must answer before the row changes; the row is the context. |
| `legacy/pages/SessionListPage.tsx:231` | The list read failed and the retry sits next to it; a toast would float over the empty list it explains. |
| `legacy/pages/GeneratePage.tsx:282` | The generate failure replaces the result panel it belongs to (`aria-live="polite"` is deliberate: it is not an assertive interruption). |
| `legacy/components/summary/ScheduleGrid.tsx:320` | A failed score write for one game, with that game's retry; the pairing is the point. |
| `legacy/components/summary/ScheduleGrid.tsx:385` | Score validation under the score inputs it refers to. |
| `legacy/pages/RankingsPage.tsx:139` | The ranking read failed and the retry is beside it. |
| `legacy/pages/HomePage.tsx:87` | The draft card failed to load, and the card is what is missing. |
| `legacy/components/summary/ShareLinkPanel.tsx:204` | The share code was rejected; the message belongs under the code it rejected. |
| `legacy/components/AccountSessions.tsx:126` | The session list failed to load, where the list would have been. |

## The z ladder

`src/index.css` names the layers so no component picks a number:
10 sticky row, 20 dropdown, 30 app header, 50 overlay, 60 toast. `z-toast` is
the only step above an overlay, which is what a toast has to be.
