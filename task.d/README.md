# Task runner

`./task <target> [args...]`

The dispatcher resolves `task.d/<target>.sh` and executes it with `sh`. The target
name is always the file name; there are no aliases and no hidden targets. An
unknown target prints the list and exits 2.

## Guaranteed environment

| Variable | Meaning |
|---|---|
| `REPO_ROOT` | absolute path of this worktree |
| `WORKTREE` | sanitized basename + 8-char digest of the absolute path |
| `NIMCACHE_CHECK` | `$REPO_ROOT/.cache/$WORKTREE/check` |
| `NIMCACHE_BUILD` | `$REPO_ROOT/.cache/$WORKTREE/build` |

Two worktrees never share a cache directory. `check` and `build` keep separate
directories so switching between them does not churn artefacts; passing an
explicit `--nimcache` does not add a suffix.

## Targets

| Target | Purpose | Needs database |
|---|---|---|
| `check` | `nim check`, unit tests, archcheck when present | no |
| `build` | release build into `.cache/$WORKTREE/bin/` | no |
| `test` | unit + integration tests | integration only |
| `verify <module>` | build and test one module | when it has integration tests |
| `ci` | check + build + test + contract check | same as `test` |

## Rules

- Every script starts with `set -eu` (inherited from `lib.sh`) and exits non-zero
  on failure. Use `fail "message"` for errors.
- Tests live next to their module. Files under `tests/integration/` only run when
  `INTEGRATION=1` (set by `test`, not by `check`).
- `.cache/` and `nimcache/` are ignored by Git.

## Timing on the development machine (2026-11-03)

- Cold `./task check` (empty `.cache`): 2.4 s
- Warm `./task check`: 2.2 s
- `./task build` warm: 2.2 s
