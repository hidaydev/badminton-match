# RC 2.0.0 — open items (untracked scratch file)

Updated: 7 November 2026
Branch: `release/2.0.0-rc.1`, 4 commits ahead of origin, none pushed since `916b7d3`
`main` untouched at `356e334` (HEAD is also 137 commits behind `main`: the merge is not a fast-forward)

## Decisions taken

| Item | Decision |
| --- | --- |
| Claim self-decision rule | Deferred. Rule stays. |
| Pending claim queue | Built (`736b576`), local. |
| Rama bound to a removed member | Released by the owner; `user_id` null. |
| Merge to main + cutover | Owner decides when. |
| `VITE_WS_BASE` on the production Vercel project | Deferred by the owner. Risk: WebSocket may fail there. |
| Seed default for directory / join requests (`false`) | Accepted. |
| Worktrees + local test DB | Cleaned. |
| `check:tailwind` arbitrary classes | Fixed (`ed66dfb`). |
| `Makefile`, dead root scripts, dead import script | Removed (`217dd49`). |
| RC scripts executable bit | Fixed (`f6ce0c2`). |
| `docs/audit` guard | Fixed (`669ae85`): hook matches `docs/audits?`, `.gitignore` carries the path, `.gitignore` junk cleaned. |
| P0 stale docs | Fixed (`5de6dbd`): 13 files. |
| Google OAuth user cap (100) | Not a constraint. Data Access has no sensitive/restricted scopes (all three tables empty) and the counter still reads 0/100 after a real login. No verification, no broker, no code change. Guardrail: never add a sensitive scope to project `sonic-signifier-481902-v7`, the cap is lifetime and cannot be reset. |
| TBD slots | Fixed (`468c23e`): placeholders publish as an empty side instead of a registered player. Owner chose "empty side, game void". A pair with one real name keeps that player. |
| Sign out from "No community yet" | Fixed (`abd5165`): the screen is the only signed-in route outside `HomeLayout`, so it had no account menu. Added a local account row. Same gap exists on `InvitePage` (dead or expired invite) — not fixed. |
| Touch targets 44px | Fixed (`af5a6cd`), reviewer defects fixed in `7ccde11`: toggle keeps a 24px box with a 44px hit area, row spacing raised so hit areas do not overlap, bracket/scroll clipping fixed, scoreboard glyphs get a width floor. |

## Local commits waiting for a push

- `f6ce0c2` `fix(ops)`: mark the RC scripts executable
- `669ae85` `chore(repo)`: audit guard + `.gitignore` cleanup
- `5de6dbd` `docs`: correct the P0 stale claims
- `217dd49` `chore(repo)`: drop Makefile and dead import script
- `736b576` `feat(community)`: pending claims queue
- `ed66dfb` `fix(web)`: named utilities instead of arbitrary widths

## Audit results

### Parity vs `main` (48 routes -> 75 operations)

Most differences are `changed by design`. Real gaps:

1. Old share links `/s/<16 hex>` no longer resolve; the importer creates no `session.links`.
2. TBD slots become real players (`resolveSnapshotPlayers`, `putSchedule`). **Fixed** `468c23e`.
3. No auto-lock; a played session stays unrated until the host presses "Finish session".
4. Default `majadu30` refuses a 21-19 game on a new session.
5. Share links expire after 30 days, while the PRD says no expiry.
6. `fix_matches` is device-local (localStorage only).
7. Celebration overlay removed (cosmetic).

### Docs (85 files, 1.18 MiB) — P0 fixed in `5de6dbd`, guard in `669ae85`

Fixed: guard path, `google-oauth.md`, `__Host-` claims, migration count 27/28 -> 30,
`export.*` config claims, architecture line refs.

Still open (P1/P2):

- Frozen hash gate out of date for TECH-SPEC / PRD / CROSS-CHECK (owner decision).
- `docs/plan/scoring-presets.md` still says "planning only" although 0029/0030 shipped.
- `docs/audit/*` and `docs/plan/*` archive headers.
- `testdata/parity/v2/README.md` still counts 74 / 73 instead of 75.
- `task.d/README.md` target table incomplete.
- `docs/design-system.md` "last updated" date stale (folds into the touch-target pass).

### Design system (34 files sampled)

Done: touch targets (`af5a6cd`); `docs/design-system.md` now documents the shipped
`rounded-xl min-h-11` input and the `bg-accent` button instead of the old
`rounded-lg h-9` / `indigo-600`.

Open:

- Extract `Button`/`ButtonLink`, `Card`, `PageHeader` (batches 2-3).
- `Sheet` in 5 legacy dialogs; `IconButton`.
- `role="alert"` missing on two legacy pages; `PlayerMatchDetailSheet` without dialog semantics.
- `SettingsPage` members list has no empty state.
- Legacy copy still hardcoded English.

Done: `Field`/`Input`/`Select`/`ErrorText` (`779ef2d`), 18 fields and 12 error
texts across 6 V2 files. `aria-live` dropped from 5 alerts.
Reviewer fixes to the touch-target commit: `7ccde11`.

### Repo hygiene

Done: Makefile, three dead root scripts, dead import script, RC script modes, 8 merged local branches, fresh `--all` bundle in `.local/backups/`.

Pending sign-off:

- 14 unmerged pre-rewrite local branches (now backed up by the verified bundle).
- 35 remote topic branches.
- Unread env keys `MAJADU_ENV`, `PUBLIC_BASE_URL` in the v2/RC templates.
- `.gitignore`: duplicated `dump/`, stale `/scripts/`, `.env*` hides future templates.
- `apps/scoreboard` is not built by CI.
- Duplicate `@axe-core/playwright` in `apps/web`.
- Local `.cache` is 641 MB (deletion was blocked; owner can run `rm -rf .cache`).
- `.opencode/PROMPT.md` still describes a Go backend.

## Still open

1. Claim self-decision policy.
2. Production `VITE_WS_BASE`.
3. PR to `main` (none open).
4. Cutover checklist: revert the RC rewrite in `apps/web/vercel.json`, merge (not FF), tag `v2.0.0`, run `cutover.sh`.
5. Production settings after cutover: directory and join requests start at `false`.
6. Audit of the 137 `main` commits absent from this branch.

## Known noise

- CSP inline-script warning: extension-injected document, UUID name, hash changes per load.
- `-webkit-text-size-adjust:100%`: Tailwind preflight, dropped harmlessly by Firefox.