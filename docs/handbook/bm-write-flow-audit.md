# BM Write Flow Audit

Last updated: 2026-07-16

This document audits the main write flows after the local app was moved to the
normalized `bm` schema.

Important boundary:

- local app target: direct `bm.*` RPC access
- external compatibility surface, if retained: `public.bm_*`
- historical bridge context: `badminton_match`

The goal here is not to preserve legacy behavior forever. The goal is to be
explicit about what is safe, what is acceptable for local use, and what is not
yet final-grade.

## Current Operating Rule

For this branch, the intended application surface is:

- `bm.publish_session`
- `bm.get_session`
- `bm.list_sessions`
- `bm.list_players`
- `bm.get_player_stats`
- `bm.publish_tournament`
- `bm.get_tournament`

The `public.bm_*` functions should be treated as compatibility-only transport
aliases for non-app consumers, not as the primary runtime contract.

Latest verification state:

- `npm run check` passes
- `npm run check:smoke` passes against the active Supabase project
- session publish, player stats, and tournament publish all completed successfully
  after the validator/runtime fixes in migrations `000031` through `000034`

## Write Flows

## 1. Initial Session Publish

Files:

- [src/components/ShareButton.tsx](/Users/user/Projects/badminton-match/src/components/ShareButton.tsx:26)
- [src/queries/endpoints.ts](/Users/user/Projects/badminton-match/src/queries/endpoints.ts:72)

Behavior:

- user publishes the current in-memory session snapshot
- if no cloud id exists yet, a short random id is created client-side
- the full snapshot is written through `bm.publish_session`

Assessment:

- acceptable for local runtime
- not ideal for long-term id generation

Risk:

- client-side short ids are collision-prone compared with UUID/share-id split
- first-publish payload depends on compatibility-shaped aggregate reconstruction
  rather than a dedicated server-issued draft/share model

Current severity:

- low for local runtime
- still worth revisiting if this branch becomes multi-user or externally shared

Recommended later fix:

- move to internal UUID + external share id

## 2. Toggle Played

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:34)

Behavior:

- reads current cached snapshot
- rewrites `playedGames`
- republishes the full session snapshot

Assessment:

- works
- acceptable for local single-user flow

Risk:

- full-snapshot last-write-wins
- stale client can overwrite unrelated newer changes

Mitigation now in place:

- optimistic version checks on publish
- live smoke coverage exercises repeat publish on real Supabase data

## 3. Set Score

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:62)

Behavior:

- updates `gameScores`
- ensures the game key is present in `playedGames`
- republishes full snapshot

Assessment:

- good operational behavior
- UX-safe enough for current local use

Risk:

- same last-write-wins issue as other snapshot rewrites

## 4. Swap Players

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:98)

Behavior:

- rewrites `schedule`
- republishes full snapshot

Assessment:

- domain behavior is correct for current app shape

Risk:

- can overwrite concurrent score/play-state edits if another client wrote later

## 5. Set Absent

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:127)

Behavior:

- rewrites `absentPlayers`
- republishes full snapshot

Assessment:

- parity-safe after recent absent-order fixes

Risk:

- still full-snapshot last-write-wins

## 6. Replace Player Name

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:155)

Behavior:

- rewrites `players[*].name`
- republishes full snapshot

Assessment:

- works as compatibility behavior
- not ideal from a canonical identity perspective

Important nuance:

- this changes session snapshot display names
- it does not create or remap canonical identities in `bm.players`
- this is still effectively a session-local rename behavior

This is acceptable only because the session runtime is still compatibility-first
at the snapshot/API boundary.

## 7. Swap Slots

File:

- [src/queries/sessions.ts](/Users/user/Projects/badminton-match/src/queries/sessions.ts:215)

Behavior:

- optimistically rewrites:
  - `schedule`
  - `playedGames`
  - `gameScores`
- republishes the current cache state after optimistic transform

Assessment:

- implementation is careful
- probably the cleanest of the mutation flows

Risk:

- still full-snapshot publish underneath

## 8. Tournament Confirm Groups

File:

- [src/queries/tournament.ts](/Users/user/Projects/badminton-match/src/queries/tournament.ts:23)

Behavior:

- generates group matches
- initializes knockout
- propagates bracket
- assigns group PICs
- publishes full tournament snapshot

Assessment:

- correct for current tournament architecture
- still snapshot-first by design

Latest note:

- tournament snapshot validation now matches the live 32-match format

Risk:

- same whole-snapshot overwrite semantics

## 9. Tournament Score Update

File:

- [src/queries/tournament.ts](/Users/user/Projects/badminton-match/src/queries/tournament.ts:50)

Behavior:

- updates one match score
- recomputes propagated bracket state
- republishes full tournament snapshot

Assessment:

- acceptable for current local usage

Risk:

- concurrent writes can clobber unrelated tournament changes

## 10. Tournament Reset / PIC Regeneration

Files:

- [src/queries/tournament.ts](/Users/user/Projects/badminton-match/src/queries/tournament.ts:83)
- [src/queries/tournament.ts](/Users/user/Projects/badminton-match/src/queries/tournament.ts:110)

Assessment:

- behavior is coherent for a snapshot-first tournament model
- no special additional schema concern beyond overwrite semantics

## Database-Side Write Model

Relevant files:

- [20260617_000003_bm_normalized_schema.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000003_bm_normalized_schema.sql:421)
- [20260617_000004_bm_compat_parity_fix.sql](/Users/user/Projects/badminton-match/supabase/migrations/20260617_000004_bm_compat_parity_fix.sql:182)

Current `bm.publish_session` behavior:

- delete existing session-owned rows for `p_id`
- rebuild normalized rows from the incoming snapshot

Why this exists:

- deterministic parity reconstruction
- easy migration from legacy snapshot behavior

Why this is not final-grade:

- poor concurrency semantics
- no partial update discipline
- hard to preserve unrelated concurrent writes safely

## Overall Assessment

For local use, current write flows are:

- operationally acceptable
- internally coherent
- not yet ideal for multi-user production concurrency

Mitigations now in place:

- optimistic version checks on publish (advisory locks)
- `onSuccess` uses `fetchQuery` instead of `setQueryData(server_response)` — prevents race conditions where a subsequent mutation's optimistic update gets overwritten by a stale server response
- debounced cloud publish on GeneratePage (300 ms trailing) with flush on unmount

The biggest structural weakness is not that the flows are incorrect.

The biggest weakness is:

- every meaningful mutation republishes the full snapshot
- the backend rebuilds the full normalized session from that snapshot

## Recommended Next Hardening Steps

1. Add optimistic concurrency to `bm.publish_session` and `bm.publish_tournament`.
2. Include `absentPlayers` in the initial publish payload from `ShareButton`.
3. Introduce internal session UUIDs plus separate external share ids.
4. Gradually move from whole-snapshot publish semantics to narrower mutation RPCs
   for high-frequency operations such as:
   - toggle played
   - set score
   - set absent
   - tournament score updates

## Practical Conclusion

If the question is:

- "can the local app run fully on `bm` now?"

The answer is yes.

If the question is:

- "is the write model already final production-grade?"

The answer is no.

It is migration-grade and local-runtime capable, with clear next steps for
hardening.
