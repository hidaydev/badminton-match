# Handover

State of `release/2.0.0-rc.1` after `3afaa78e`, the last commit that changed
behaviour, written 2026-11-10. The commit that adds this file only updates
documents; nothing in it can turn a test from green to red. This file is the
short version of what a new pair of hands needs; the long version is
`.local/rc-audit.md`, which is deliberately not tracked by git (it names secrets
paths and host details that do not belong in the repository).

Read this first, then `docs/handbook/current-status.md` for the runtime, then
`docs/ops/release.md` before touching the release.

## 1. Where the branch is

| | |
|---|---|
| Branch | `release/2.0.0-rc.1`; last behaviour-changing commit `3afaa78e`; local and `origin` agree |
| CI | green on `3afaa78e`: every job that runs on a push, `gate` included; `mutation` and `notify` are skipped as designed |
| Coverage | green on the same commit, including `ratchet` |
| Gate to cross next | `QA-04`: merging `main` and tagging `v2.0.0`, held by the owner |

`main` has not been touched and no tag exists. Promotion is the owner's call, not
an agent's.

## 2. Commits on this branch after the last wave merge

| Commit | What it does |
|---|---|
| `207728be` | e2e job installs cached browsers before paying for apt |
| `3c537df7` | README gate counts say what the tree prints |
| `88786725` | Linux coverage baseline refreshed from the merged tree, after checking that every fall came from deleted code |
| `aa366768` | export poster stays inside the viewport; the route-focus ring is suppressed on `main` and on the screen heading |
| `df637f1d` | Linux export baseline re-recorded from a throwaway branch, 26 of 28 files byte-identical |
| `a63fde1b` | every pinned browser is downloaded, because `deps-check` requires firefox |
| `4d6f7215` | dated exception for `tools/sharekeys/main.nim` under the new-file minimum |
| `b81db954` | production deploy seeds after the schema check; cutover refuses a missing or half-written share-log matcher; `host-check.sh` pages on an uncapped journal; `check` help line fixed; rotation dates in the credential table |
| `432ec32d` | one `label-meta` utility for 44 micro labels, pixel-identical |
| `995ea61e`, `a21a29ba` | the 413 assertion, first wrong then corrected: `errors.toJson` has no `request_id`, so the test now asserts the absence |
| `2adc5349`, `20994556`, `3afaa78e` | apt is skipped when the package is present, bounded when it is not; the libpcre guard sees the conditional form |

## 3. Gates, measured on this machine

```
./task test                1,524 cases in 140 suites (70 unit, 70 integration),
                           0 failed, 0 skipped
./task check --static      ok (254 Nim files, 129 TypeScript tests, proc-length
                           14 procs over 100 lines against a baseline of 14)
./task docs-check          ok (54 migrations, 76 operations)
./task e2e --grep @visual  28 passed (no baseline re-record needed)
pnpm exec vitest run       564 passed in 111 files
shelltests                 deploy_guards 87, ops_scripts 62, target_guards 19,
                           workflow_contract 5, release_guard 2, all green
```

`./task test` needs `MAJADU_PG_DSN` and, for the import suites, the four
`MAJADU_IMPORT_*` DSNs; `bm2_test` is the base and the import targets are clones
with sources loaded from `ops/dev/v1/schema.sql`.

## 4. What still has to happen before `v2.0.0`

Owner only, in this order:

1. Merge `main` into the branch, or the branch into `main`, whichever the release
   flow says, and resolve the release-notes link (`Release DoD` items 1 and 2).
2. Sign and push the tag; run the release workflow once and record the image
   digest. The `[2.0.0]` section in `CHANGELOG.md` is regenerated from
   Conventional Commits by `./task release`, so it is produced at this step, not
   before. `OPS-09`, `QA-04`, `QA-15`.
3. On the host: one deliberate `majadu-api.service` failure must produce a journal
   line and a Telegram message inside a minute, and one rollback to `:prev` must
   be rehearsed and logged (`Release DoD` items 3 and 4).
4. Set the branch protection the gate expects, or record in writing that both
   checks are required: `./task branch-protection` verifies it with `gh api`
   (`QA-22`).
5. Sign off, in writing and with a date, every P1 finding that ships open
   (`Release DoD` item 10).

Host prerequisites that were deferred by decision: webhook token, split of the
API and tools env files, first RC deploy, and the production Google login check
(`ISO-02`).

## 5. Code that is still open, and its exact size

The audit keeps one line per finding. The short list of what is genuinely left in
the repository:

- **Security:** `SEC-03` needs `.github/allowed_signers` (key material, owner).
  `SEC-05` has no advisory universe for `deps.lock`. `SEC-10` does not compare
  handler request and response keys with the spec. `QAE-02` still lacks
  `Connection: close` on the 413. `QAE-05` has no per-address cap on pending
  OAuth flows. `QAE-06` is real but expensive: giving every problem envelope a
  request id is a contract change.
- **Data:** `DB-08` lets a game row say `played` with no set. `DB-11` has no court
  foreign keys, deferred by ADR-017. `DB-16` has no RLS, deferred by ADR-018 with
  a build-time tenancy scan as the compensating control. `DB-06` lacks the
  scratch-deploy readiness case (the production seed landed).
- **Backend shape:** `BE-06` extracted one module so far and still allowlists 70
  routines for holding SQL. `SQ-05` still has `"ws-ticket"` twice. `SQ-11` still
  allows `void` in the lint rule.
- **Frontend:** `DS-03` (85 `<button>` outside `components`, five
  `disabled:opacity-*` values), `DS-16` (64 card recipes outside `Card`), `DS-17`
  (seven spinner copies), `DS-19` (three page widths), `DS-21` (27
  `transition-all`), `DS-22` (40 inline SVGs, 18 stroke widths), `DS-23` (no
  `aria-invalid`), `DS-24` (no toast primitive on 17 `role="alert"` sites),
  `DS-26` (guard covers five patterns, scoreboard has none), `CMP-06` (nine
  `let active = true`), `CMP-07` (no shared standings component), `CMP-20`
  (`ScheduleGrid` takes 41 props), `FE-13`, `FE-21`.
- **QA:** `QA-17` (load harness needs a live URL), `QA-19` (one keyboard dialog
  case), `ISO-17` (no fallback-origin login test), `ISO-18` (no dated tabletop
  exercise).

Every one of these is backlog, not a reason to hold the tag, unless the owner
decides otherwise in step 5.

## 6. Traps worth knowing before you touch anything

- **A fifteen minute job with an unbounded network step is a latent timeout.**
  GitHub reports the job as `cancelled`, not `failed`, and the log then contains
  no test result at all. Two runs died this way in apt; both steps are bounded
  now, but read the step timings before concluding a test broke.
- **Visual baselines are per platform and are never recorded by CI.** CI compares
  only. To change a Linux baseline, branch off, patch the e2e step to
  `--grep "@visual" --update-snapshots` plus an artifact upload, push that
  throwaway branch, download, copy only the files that actually differ, then
  delete the branch. The Darwin set is recorded locally with
  `./task e2e --update-snapshots`. A refactor that keeps the pixels identical
  (`label-meta`) needs no re-record; prove it by running the visual suite against
  the committed set.
- **The coverage baseline is a ratchet, not a snapshot.** Refresh it only when
  every fall in covered lines belongs to deleted code, checked per file, and only
  through the `update_baseline` dispatch. Never lower a threshold or a floor.
- **Concurrent `nim c` runs sharing `.cache/<repo>/build` corrupt the link step.**
  If you see `ld: symbol(s) not found` after a parallel run, rebuild alone before
  debugging anything.
- **`rtk` mangles repeated identifiers** (it rewrites `h1`, `cutover`, `n` in
  places). When a search returns nonsense, use `rtk bypass` or the grep tool.

## 7. Where the record lives

| Artefact | Contents |
|---|---|
| `.local/rc-audit.md` | every finding with evidence, DoD, status, the verification pass, and the CI fragility notes |
| `.local/backlog/wave4.md` | stream table, close-out, and the four commits that followed |
| `docs/handbook/current-status.md` | the numbers this handover quotes |
| `docs/ops/operations.md` | rotation register, incident format, journal cap |
| `docs/ops/release.md` | the release sequence and what is still unproven |

## 8. Next three moves

1. Owner: step 4 above, then the tag.
2. One backlog wave that cannot move a pixel: `QAE-02`, `QAE-05`, `DS-23`,
   `QA-19`, `QA-17`, `ISO-18`.
3. One baseline cycle for `DS-16`, `DS-17`, `DS-19`, `DS-21`, `DS-22`, `DS-24`,
   `DS-26`, then the same for `CMP-06`, `CMP-07`, `CMP-20` if the owner wants the
   component layer finished.
