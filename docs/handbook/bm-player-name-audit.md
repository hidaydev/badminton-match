# BM Player Name Audit

Last updated: 2026-06-17

This document audits player names found in the legacy `badminton_match`
backfill data against the live `mdef` identity layer in the Supabase `public`
schema.

This is an audit and context file. The final human decisions are recorded in:

- [bm-player-resolution-map.md](/Users/user/Projects/badminton-match/docs/handbook/bm-player-resolution-map.md:1)

## Sources Used

Legacy source:

- [supabase/seeds/20260617_legacy_snapshot_backfill.sql](/Users/user/Projects/badminton-match/supabase/seeds/20260617_legacy_snapshot_backfill.sql:1)

`mdef` reference files:

- [/Users/user/Projects/mdef/docs/database/001_schema.sql](/Users/user/Projects/mdef/docs/database/001_schema.sql:1)
- [/Users/user/Projects/mdef/lib/core/database/database_client.dart](/Users/user/Projects/mdef/lib/core/database/database_client.dart:1)

Live DB sources queried:

- `public.players`
- `public.player_aliases`

Normalization rule used during comparison:

- lowercase
- trim
- collapse repeated whitespace

## Summary

- unique legacy player-like names found in snapshot data: `84`
- the live `mdef` DB already resolves many names that were not present in the
  repo seed file
- the actual unresolved set is therefore much smaller than a seed-only audit
  would suggest

Main takeaway:

- `bm` should be designed against the live `mdef` identity model, not against
  the seed file alone
- `bm.players` may still contain new canonicals that do not exist in `mdef`,
  because this phase does not require ELO seed data

## Identity Model Observed In Live `mdef`

The live `mdef` identity layer behaves as expected:

- canonical players live in `public.players`
- aliases live in `public.player_aliases`
- aliases are stored lowercase
- aliases resolve to exactly one canonical player

This matches the intended design for `bm`.

## Legacy Names Already Resolved By Live `mdef`

### Direct canonical or trivial normalized matches

- `Adam`
- `Agha`
- `Akid`
- `Andhika`
- `Anas`
- `Azzam`
- `Boby`
- `Bowo`
- `Cahaya`
- `Dendi`
- `Dian`
- `Dimas`
- `Dwi`
- `Ega`
- `Euis`
- `Fahmi`
- `Faiz`
- `Fredi`
- `Hafian`
- `Ismet`
- `Jihan`
- `Lita`
- `Lulud`
- `Maul`
- `Nisa`
- `Novian`
- `Rafi`
- `Raihan`
- `Raka`
- `Rakha`
- `Rizky`
- `Rudi`
- `Tari`
- `Vieri`
- `Vina`
- `Visi`
- `Zaid`
- `Zainal`

### Resolved through live aliases or additional canonicals

- `Angel` -> canonical `Angel`
- `Anjed` -> canonical `Andri`
- `Bagas` -> canonical `Bowo`
- `Damm` -> canonical `Adam`
- `Dayat` -> canonical `Hidayat`
- `Dika` -> canonical `Andhika`
- `Dms` -> canonical `Dimas`
- `Fachri` -> canonical `Fachri`
- `Febri` -> canonical `Febri`
- `fiya` -> canonical `Fiya`
- `Ginanjar` -> canonical `Ginanjar`
- `Hidayah` -> canonical `Hidayah`
- `Jeki (Temen Anas)` -> canonical `Jeki`
- `Kahfi` -> canonical `Kahfi`
- `Mamski` -> canonical `Mamski`
- `Mr. Rama Udin` -> canonical `Rama`
- `Nindy` -> canonical `Nindya`
- `Nitho` -> canonical `Nitho`
- `Randra (Temen Anas)` -> canonical `Randra`
- `Shan` -> canonical `Shania`
- `Surya` -> canonical `Suryadi`
- `Tin` -> canonical `Tin`
- `Via` -> canonical `Via`

## Resolved But Important To Explicitly Bless

These mappings were surprising enough that they should not be treated as
self-evident. They have now been explicitly confirmed by the user:

- `Anjed` -> `Andri`
- `Bagas` -> `Bowo`
- `Damm` -> `Adam`
- `Dayat` -> `Hidayat`
- `Mr. Rama Udin` -> `Rama`

## Unresolved After Live DB Lookup

These names were not found in the live `mdef` canonical or alias tables during
audit:

- `Agh`
- `Ari (Tmn Dimas)`
- `Arin`
- `Bobby`
- `Dhika`
- `Feri (Tmn Novian)`
- `Hapid`
- `Iky`
- `Indah`
- `Jihan Angkle`
- `lud`
- `Pak hong`
- `Pina`
- `Radita`
- `Reggi`
- `Rifki`
- `silvi (Tmn Agha)`
- `Tommy`
- `Wahyu`

These are now covered by explicit human decisions in the resolution map.

## Human Decisions Captured

The following decisions are now recorded formally in the resolution map:

### Confirmed alias mappings

- `Agh` -> `Agha`
- `Bobby` -> `Boby`
- `Didik` -> `Didick`
- `Dhika` -> `Andhika`
- `Feri (Tmn Novian)` -> `Feri`
- `Iky` -> `Rizky`
- `Jihan Angkle` -> `Jihan`
- `lud` -> `Lulud`
- `Pak hong` -> `Mr. Hong`
- `Pina` -> `Vina`

### Conditional canonical creation

If missing from live `mdef`, still acceptable to create directly in `bm`:

- `Aria` -> `Aria`
- `Ari (Tmn Dimas)` -> `Ari`
- `Arin` -> `Arin`
- `Hapid` -> `Hafidh`
- `Indah` -> `Indah`
- `Radita` -> `Radita`
- `Reggi` -> `Reggi`
- `Rifki` -> `Rifki`
- `silvi (Tmn Agha)` -> `Silvi`
- `Tommy` -> `Tommy`
- `Wahyu` -> `Wahyu`

## Important Schema Implication

One important clarification came out of the discussion:

- `bm.players` in this phase is not an ELO-bearing analytics table
- therefore, lack of ELO seed data is **not** a blocker for creating a canonical
  player in `bm`

This matters because it means:

- we do not need to skip real players just because `mdef` does not already
  contain them
- canonical-only backfill remains feasible

## Tournament Pair Label Evidence

The legacy tournament snapshot includes pair labels such as:

- `Iky & Raihan`
- `Bowo & Didik`

This provides extra signal for two migration points:

- `Iky` is important enough to deserve alias treatment
- `Didik` is now confirmed as an alias of canonical `Didick`

## Remaining Manual Clarification List

No materially important unresolved player-name mappings remain in the current
legacy snapshot set.

At this point the materially important unresolved items are:

- `Aria`
- `Didik`

Everything else from the prior audit now has either:

- a live DB resolution
- or an explicit human decision

## Recommendations For `bm`

1. Seed `bm.players` from reviewed live canonical data, not the repo seed alone.
2. Seed `bm.player_aliases` from approved live aliases plus the newly approved
   mappings in the resolution map.
3. Allow creation of new canonical `bm.players` rows when a reviewed human
   decision says a legacy player is real but absent from `mdef`.
4. Keep unresolved-name reporting in the backfill pipeline.
5. Do not silently guess unresolved names beyond the approved resolution map.

## Next Artifacts

The next useful outputs should be:

1. `bm` player and alias seed SQL
2. concrete `bm` DDL
3. backfill validation SQL against the approved resolution map
