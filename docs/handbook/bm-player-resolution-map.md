# BM Player Resolution Map

Last updated: 2026-06-17

This file records explicit human decisions for mapping legacy player labels from
`badminton_match` into canonical player identities for the new `bm` schema.

Important implementation note:

- `bm.players` in the current normalization plan is an operational identity
  table, not an ELO table
- therefore, a player does **not** need existing `mdef` seed ELO data in order
  to exist in `bm.players`
- if a legacy name should represent a real canonical person but does not yet
  exist in `mdef public.players`, we can still create it directly in `bm`

This means the phrase "skip if not in public.players" should be interpreted as:

- do not force reuse of an `mdef` canonical row
- but create a new canonical `bm.players` row if required to backfill a session
  cleanly

## Confirmed Existing Live Mappings

These were already present in live `mdef` data and were explicitly confirmed as
correct:

- `Anjed` -> canonical `Andri`
- `Bagas` -> canonical `Bowo`
- `Damm` -> canonical `Adam`
- `Dayat` -> canonical `Hidayat`
- `Mr. Rama Udin` -> canonical `Rama`

## Confirmed Alias Mappings

These should be seeded or preserved as aliases in `bm.player_aliases`:

- `Agh` -> canonical `Agha`
- `Bobby` -> canonical `Boby`
- `Didik` -> canonical `Didick`
- `Dhika` -> canonical `Andhika`
- `Feri (Tmn Novian)` -> canonical `Feri`
- `Iky` -> canonical `Rizky`
- `Jihan Angkle` -> canonical `Jihan`
- `lud` -> canonical `Lulud`
- `Pak hong` -> canonical `Mr. Hong`
- `Pina` -> canonical `Vina`

## Confirmed New Canonical Or Canonical Creation Decisions

These should resolve to the named canonical player. If the canonical does not
already exist in live `mdef public.players`, it is acceptable to create it in
`bm.players`.

- `Aria` -> canonical `Aria`
- `Ari (Tmn Dimas)` -> canonical `Ari`
- `Arin` -> canonical `Arin`
- `Hapid` -> canonical `Hafidh`
- `Indah` -> canonical `Indah`
- `Radita` -> canonical `Radita`
- `Reggi` -> canonical `Reggi`
- `Rifki` -> canonical `Rifki`
- `silvi (Tmn Agha)` -> canonical `Silvi`
- `Tommy` -> canonical `Tommy`
- `Wahyu` -> canonical `Wahyu`

## Migration Interpretation Rules

When building the `bm` backfill:

1. If a legacy label matches a confirmed alias mapping above:
   - resolve to the declared canonical player
   - insert alias into `bm.player_aliases` if not already present

2. If a legacy label maps to a confirmed new canonical or canonical creation
   decision:
   - try to resolve against approved canonical names first
   - if canonical exists in `mdef`, reuse the canonical name
   - if canonical does not exist in `mdef`, create a new canonical player in
     `bm.players`
   - then insert the legacy label as an alias in `bm.player_aliases`

## Practical Consequence For Backfill

Because the target `bm` schema is canonical-only:

- we should prefer creating new canonical `bm.players` rows over skipping real
  players that appear in legacy sessions
- otherwise, any session containing such a player would become impossible to
  backfill cleanly

Therefore, for the "skip if not in public.players" cases, the operationally
safe interpretation is:

- create canonical in `bm`
- do not require presence in `mdef`

## Next Use

This file should drive:

- `bm.players` seed generation
- `bm.player_aliases` seed generation
- legacy session backfill validation
