# Google Sheets Sync — Design Spec

**Date:** 2026-04-29
**Branch:** feature/google-sheets

## Problem

The current share mechanism encodes the full app state into a URL (via lz-string compression). This produces URLs too long to share conveniently and provides no sync — if the organiser updates the schedule or players enter scores on different devices, state diverges.

## Goal

- Short shareable URL (e.g. `badminton-pair.vercel.app/s/abc123`)
- Anyone with the URL can view the session and update scores / mark games played
- No user accounts required
- Manual refresh to pull latest state (no real-time requirement)

## Architecture

```
Organizer's browser (Vite app)
  │
  │ POST full session state
  ▼
Google Apps Script Web App  ←── hosted free on Google Drive, no server needed
  │
  │ read/write
  ▼
Google Sheet — "Sessions" tab (one row per session)
  ▲
  │ GET session by ID
  │
Anyone's browser → /s/:sessionId
  └── marks games played, enters scores → POST back to Apps Script
```

### Flow

1. Organiser sets up session, adds players, generates schedule — all unchanged, stays local.
2. New **Share** button appears after schedule generation → POSTs state to Apps Script → receives short URL.
3. Organiser shares URL (WhatsApp, etc.).
4. Anyone opens `/s/:sessionId` → app fetches state from Apps Script → Summary modal opens automatically.
5. User ticks a game or saves a score → app POSTs full updated state back to Apps Script.
6. **Refresh** button in the modal header pulls the latest state from cloud.

## Data Model

### Google Sheet — "Sessions" tab

| Column | Name | Type | Notes |
|--------|------|------|-------|
| A | session_id | string | 6-char nanoid, e.g. `abc123` |
| B | created_at | ISO timestamp | set on first publish |
| C | updated_at | ISO timestamp | updated on every POST |
| D | data | JSON string | full session snapshot |

### JSON snapshot shape (column D)

```ts
{
  session: SessionConfig,
  players: Player[],
  fixMatches: FixMatch[],
  schedule: ScheduleSlot[],
  playedGames: string[],
  gameScores: Record<string, GameScore>,
}
```

`summaryOpen` and `lastResult` are excluded — UI state only.

Concurrency: last-write-wins. Acceptable since players enter scores for different games.

## Apps Script API

Single deployed Web App URL (stored in `VITE_APPS_SCRIPT_URL` env var).

### GET `?id=abc123`
Returns the JSON data for the session.

**Response (200):**
```json
{ "ok": true, "data": { ...snapshot } }
```

**Response (404):**
```json
{ "ok": false, "error": "not found" }
```

### POST — body `{ id: string, data: object }`
Creates or overwrites the row for the given session ID. Updates `updated_at`.

**Response (200):**
```json
{ "ok": true }
```

## Frontend Changes

### New files

| File | Purpose |
|------|---------|
| `src/utils/cloudSync.ts` | `getSession(id)` and `publishSession(id, data)` — thin `fetch()` wrappers |
| `src/pages/SharedSessionPage.tsx` | Route `/s/:sessionId` — fetches cloud state, renders Summary modal, handles score/checklist writes |
| `src/components/ShareButton.tsx` | Button in GeneratePage — publishes state and shows copyable short URL |

### Store changes

One new field added to `AppState`:

```ts
cloudSessionId: string | null  // set when organiser publishes; null otherwise
```

No changes to existing actions or localStorage persistence shape (version bump not required — new field defaults to null).

### Route changes

```
/s/:sessionId  →  SharedSessionPage  (public, no auth guards)
```

Added to [src/App.tsx](../../src/App.tsx) alongside existing routes.

### GeneratePage changes

- "Share" button rendered below the schedule, only after a schedule exists.
- On click: generates a 6-char session ID (or reuses `cloudSessionId` if already published), POSTs to Apps Script, stores ID in `cloudSessionId`, shows copyable URL in a small inline dialog.
- Re-publishing (e.g. after retrying generation) overwrites the same session ID.

### SharedSessionPage behaviour

- On mount: GET session from Apps Script using `:sessionId` from URL params.
- Renders `SummaryModal` with fetched data, always open (no toggle needed — the route IS the modal).
- Checklist tick / score save: update local state then POST full snapshot back to Apps Script.
- "Refresh" button in modal header: re-fetches from Apps Script and replaces local state.
- Loading state: spinner while fetching.
- Error state: simple message if session not found or network failure.

### Unchanged

- Setup → Players → Constraints → Generate flow: no changes.
- Existing localStorage store (other than the one new field).
- Existing share-via-URL mechanism: still works as a fallback.

## Environment Variables

| Variable | Where set | Value |
|----------|-----------|-------|
| `VITE_APPS_SCRIPT_URL` | Vercel project settings + local `.env.local` | Apps Script deployment URL |

## Apps Script Setup (one-time, manual)

1. Open the Google Sheet → Extensions → Apps Script.
2. Paste the Web App script (to be written during implementation).
3. Deploy as Web App: execute as **Me**, access **Anyone**.
4. Copy deployment URL into `VITE_APPS_SCRIPT_URL`.

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| Apps Script unreachable | Show error toast; user can retry |
| Session ID not found | Show "Session not found" message on SharedSessionPage |
| POST fails | Show error toast; state is not lost (still in local memory) |
| Concurrent writes | Last-write-wins; acceptable for this use case |
