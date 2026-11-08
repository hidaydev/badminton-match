# Pre-push: keep internal notes out of the public repository

This repository is public. Internal working notes (audits and plan reviews) are
not product documentation and must not enter the published history. The
directories `docs/audit/`, `docs/audits/`, and `docs/plan/reviews/` are no longer
in the tree; the guards stay in place for notes created again later.

Two layers of guards:

| Layer | File | Coverage |
| --- | --- | --- |
| Ignore | `.gitignore` → `docs/audit/` | applies in every clone and in CI |
| Hook | `.githooks/pre-push` | only machines that have run `./task hooks` |

The hook alone is not enough: `core.hooksPath` is local configuration, so a
fresh clone does not have it. That is why `docs/audit/` is in the tracked
`.gitignore`. Local notes are stored in `.local/` (gitignored).

## Installing the hook

```sh
./task hooks
```

That command sets `core.hooksPath=.githooks` for this repo.

## What gets rejected

`.githooks/pre-push` rejects a push if `HEAD` contains files under those paths:

```
pre-push: these paths belong in .local/, not the public repository:
docs/audit/...
```

The pattern is `^docs/(audits?|plan/reviews)/`, so both `docs/audit/` and
`docs/audits/` are caught.

If that happens, move the files to `.local/` and commit the removal;
do not bypass the hook with `--no-verify` unless you really know why.

## History

The published history has already been rewritten once: both directories were
removed from all refs with `git filter-repo --invert-paths`, so that
`git log --all -- docs/audit docs/audits docs/plan/reviews` is empty. All commit
SHAs changed and old branches were rewritten too. The pre-rewrite bundle is no
longer kept on this machine; take it from a copy that still has it if an old
commit needs to be recovered.