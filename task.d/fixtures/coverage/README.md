# Coverage gate fixtures

Each directory is a model the gate can judge without compiling anything:

```sh
./task coverage --model task.d/fixtures/coverage/<name>
```

A model is three small tables:

- `baseline.json` - the previous measurement, in
  `coverage-baseline-<platform>.json`'s schema (floor, low file count, total,
  domain rows and per-file rows, all as line counts).
- `files.tsv` - the current report: `path<TAB>executable lines<TAB>covered lines`.
- `changed.tsv` - optional; the changed executable lines already intersected
  with the report, as `path<TAB>line<TAB>hits`. Without it the diff check
  reports "no changed executable Nim lines" and skips.

The paths are labels only: a model never touches the tree it lives in.

| Model | What it must prove | Exit |
| --- | --- | --- |
| `passing` | A clean model passes, so the failing models fail for their own rule and not for parsing. | 0 |
| `new-zero-file` | A new file at 0% fails even though the total and the domain both rose. | 1 |
| `file-decrease` | One file drops 90% to 80% while the domain and the total stay flat: the file row catches it. | 1 |
| `domain-hides-file` | One file drops 50% to 30% while the total and the domain rise: a domain-only gate would have missed it. | 1 |
| `diff-below-90` | The ratchet holds, but only 5 of 10 changed lines are covered. | 1 |
| `branch-axis` | The report carries BRF/BRH per file and for the total, and `--update` records both axes. | 0 |
| `low-file-growth` | A file slips from 50.01% to 49.99% (inside the 0.1 point tolerance) and becomes the first file below the per-file floor: the count grows from 0. | 1 |

The update rules are fixtures too, and they never rewrite the checked-in files:

```sh
./task coverage --model task.d/fixtures/coverage/file-decrease --update
# refuses: 90.00% -> 80.00%, exit 1

./task coverage --model task.d/fixtures/coverage/file-decrease --update --allow-decrease
# prints the accepted regression, exit 0, baseline left in the worktree cache
```