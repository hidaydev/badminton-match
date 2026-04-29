# Session Title & Date Design

**Date:** 2026-04-29  
**Status:** Approved

## Overview

Add `title` and `date` as required fields to every session. Both fields are shown on setup, enforced before the session locks, displayed on the view/summary page, and automatically included in the Google Sheets cloud sync.

## Data Model

Add two fields to `SessionConfig` in `src/store/index.ts`:

```ts
interface SessionConfig {
  title: string   // e.g. "Sunday Morning Session"
  date: string    // ISO date string, e.g. "2026-04-29"
  // ...existing fields
}
```

Default values: `title: ''`, `date: <today's ISO date>`.

Store version bumped from **11 → 12**. Migration resets to defaults (existing pattern — no change needed).

## SetupPage Changes

Two new inputs appear at the **top** of the setup form card, above the courts/players block:

- **Title** — plain `<input type="text">` with placeholder "e.g. Sunday Morning Session". Required (non-empty after trim).
- **Date** — `<input type="date">` defaulting to today's date in `YYYY-MM-DD` format. Required (non-empty).

Both inputs are disabled once the session is locked (consistent with all other setup fields).

The "Start Session →" button is disabled when:
- `title.trim() === ''`, OR
- `date === ''`, OR
- existing `courtError` is present

Store actions added: `setTitle(title: string)` and `setDate(date: string)`. Both reset `schedule` and `lastResult` to `null` (consistent with other session mutations that invalidate results — though in practice title/date changes pre-lock won't have a schedule yet).

## SummaryModal / View Page

The `SummaryModal` header currently has no session title. Add `title` and `date` as new props to `SummaryModal`, and display them at the top of the modal:

- Session title in a prominent style (e.g. `text-white font-bold`)
- Date formatted for display (e.g. "Tuesday, 29 April 2026")

Both callers must pass the new props:
- **`GeneratePage`** — reads from the active store session
- **`SharedSessionPage`** — reads from `snapshot.session` (already has access since `CloudSnapshot` includes `session: SessionConfig`)

## Cloud Sync

No backend changes required. `CloudSnapshot` already includes `session: SessionConfig`, so `title` and `date` are automatically published via the existing `publishSession` call. The Google Sheet will receive the new fields as part of the session JSON blob.

## Out of Scope

- Session list page (deferred)
- Uniqueness enforcement on title
- Backend schema changes to Apps Script
