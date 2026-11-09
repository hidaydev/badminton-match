# Charter: the public HTTP boundary

Release candidate 2.0.0-rc.1, wave 3. The audit findings QAE-02 to QAE-06 all
sit on the anonymous edge of the API: what a caller with no session can do and
what the process says about it. The generated contract describes the happy
paths, so this charter targets the seams around them.

## Mission

Find behaviour a client or an operator would misread: a network failure where a
decision was promised, a health check that is true of the wrong process, a write
volume that nothing bounds, and a log stream that only mostly parses.

## Areas and time boxes

| Area | Question | Time box |
|---|---|---|
| Body limits | Does every oversized body get the problem envelope, including at the boundary? | 60 min |
| Test-route flag | Can a single environment variable leave a process that looks healthy and serves nothing? | 60 min |
| Join request | What does the 202 acknowledgement promise, and what does it record? | 30 min |
| Auth start | How many rows does one anonymous caller create, and what bounds them? | 30 min |
| Log shape | Does every line the process emits parse as one JSON object? | 45 min |

## Heuristics

- Boundary values around a configured limit: exactly at it, one byte over, one
  byte under, and far over (the transport ceiling).
- Absent authentication, absent body, malformed body, unknown identifiers.
- Volume: how many writes does one caller cause per minute, and which limit
  answers first.
- Parity: the same rejection must look the same as every other rejection, in the
  response and in the log.
- Intent in the comments: where the source states a rule, the observation either
  confirms it or is a finding.

## Oracles

- `platform.config` holds the effective limits, so a test reads the limit
  instead of repeating it.
- The problem envelope: one shape, `status`, `code`, `detail`, `i18nKey`.
- The readiness contract in `apps/api/README.md`.
- "One JSON object per line" for everything the process writes to stdout.
- The seeded database from `db/seeds`, which is what a fresh deployment has.

## Environment

- Branch `w3/qae`, based on `release/2.0.0-rc.1` at `0e3000c1`.
- Scratch database `bm2_w3qa`, created with `dbtools migrate` and
  `dbtools seed`, so it holds the seeded config and nothing else.
- Release build from `./task build` on port 8098, plus a debug build from the
  same tree for the test-route flag, which a release build compiles out.
- No session cookie was obtained. Every request in these sessions is anonymous.

## Out of scope

- Authenticated flows, role boundaries and multi-community isolation. The e2e
  suite covers the member role; an owner walk is a separate charter.
- Browser rendering, which `e2e/a11y.spec.ts` and `e2e/visual.spec.ts` own.
- Concurrency: two writers on one session are covered by
  `session-occ.spec.ts`.

## Exit criteria

Each finding ends as a test or guard that fails when the behaviour returns, or
as a session note that names the layer which still has to change. A finding does
not close on an intention.
