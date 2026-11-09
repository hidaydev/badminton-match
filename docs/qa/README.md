# Exploratory QA: charters and session notes

This directory holds the parts of exploratory testing that outlive a single run:

- `charter-*.md` is what a session sets out to look at. It names the area, the
  time box, the oracles and what is out of scope, so a later reader can tell
  whether the untested part was a decision or an oversight.
- `sessions/<ID>-*.md` is what a session actually observed. Every command and
  every output in one was run and copied, never reconstructed from the source.
  A session note that cannot name the commands behind an observation is a wish,
  not evidence.

Findings are tracked outside this repository (the release-candidate audit) under
IDs such as `QAE-02`. A session note repeats the ID in its name so the audit row
and the evidence are one lookup apart.

## Rule for closing a finding

A finding closes with one of three artefacts, in this order of preference:

1. A test or a guard in this repository that fails when the behaviour returns.
   `e2e/api.spec.ts` drives the real API from the e2e harness, and
   `tools/qa/tests/` holds checks that need the delivery layer but not a socket.
2. A session note that records the gap and names the layer that still has to
   change, when the fix is outside the QA tree (`apps/`, `db/`, `ops/`).
3. A session note that records the behaviour as intended, with the contract
   consequence written down, when the finding turns out not to be a defect.

An observation made by reading source only belongs in the note as an
assumption, never as a result.

## Index

| Charter | Sessions |
|---|---|
| `charter-http-boundary.md` | `QAE-02`, `QAE-03`, `QAE-04`, `QAE-05`, `QAE-06` |
