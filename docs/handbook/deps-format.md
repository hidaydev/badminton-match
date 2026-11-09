# `deps.lock` format

Status: implemented. Reference: `deps.lock`, `./task deps-check`, and
`./task deps-install`.

`deps.lock` is the single source of truth for toolchain versions, Nim packages, and
non-Nim gate tools. There is no `nimble.lock`: dependencies are installed manually, then
`./task deps-check` verifies that what is actually installed matches what is
recorded. Timestamps are never compared.

## 1. File shape

```text
# comments start with '#'
tree <sha256>
<name> <version> <source> <sha256>
...
```

- **One entry per line, exactly four fields**, separated by one space. Fields must not
  contain spaces.
- `name` is unique. Duplicates fail `deps-check`.
- `version` is the installed version. When a tool has no version metadata
  (for example fonts), write `-`; **do not invent a number**. A tool that is not
  installed is written as `absent` with `sha256` set to `-`.
- `sha256` is the content digest. `-` means the entry has no content to hash
  (toolchain, browser, npm package).
- The `tree` line must appear exactly once, at the top. Comments and line order do not
  affect `tree`; entries are sorted with `LC_ALL=C` when it is computed.

## 2. `source`: the schemes

| Scheme | Meaning | How it is verified |
|---|---|---|
| `nimble:<url>` | Nim package in `$NIMBLE_DIR/pkgs2` (`~/.nimble/pkgs2` by default) | exactly one `name-version-*` directory must exist, its contents are hashed |
| `nimble:<url>@<commit>` | the same, but the commit must match `vcsRevision` in `nimblemeta.json` | idem + commit check |
| `repo:<relative path>` | file or directory in the repo | file: sha256 of the bytes; directory: content digest |
| `toolchain:<command>` | compiler/tool on `PATH` (`nim`, `gcovr`, `lcov`) | `version` `absent` → the command must **not** exist; otherwise the version is compared |
| `npm:<package>` | npm package from the FE workspace | `apps/web/node_modules/<package>/package.json` (`version` → `version`) |
| `playwright-browser:<name>` | Playwright browser build `<name>-<version>` | directory `<browser-cache>/<name>-<version>/INSTALLATION_COMPLETE` |
| `docker:<image:tag>` | container base image in `apps/api/Dockerfile` | the matching `FROM` must carry `@<sha256>` equal to the fourth field |

Browser cache: `PLAYWRIGHT_BROWSERS_PATH` when set, otherwise
`~/Library/Caches/ms-playwright` (macOS) or `~/.cache/ms-playwright` (others).

An unknown scheme is a failure, not an entry that is skipped.

## 3. Digest algorithm

**Package / directory** (`nimble:` and `repo:` pointing at a directory):

```text
for each regular file under the directory, sorted LC_ALL=C by relative path:
    <relative-path>\n
    <sha256 of the file content>\n
sha256 of the concatenation of the bytes above
```

`nimblemeta.json` is **excluded**: the `files` array inside it follows filesystem order
at install time, so the hash could differ between machines. Timestamps,
mode, owner, and `.git` contents never enter the digest.

**Single file** (`repo:` pointing at a file): sha256 of the file bytes.

**Docker image** (`docker:`): the digest is not hashed; it is read from the
matching `FROM <image>@sha256:...` line and must equal the fourth field
verbatim. A tag-only `FROM` is a failure, not an entry without a digest.

**`tree`**: the concatenation of canonical entry lines (`name version source sha256`)
sorted with `LC_ALL=C`, each terminated by `\n`, then hashed with sha256. Because
each line carries a content digest, `tree` also changes when one package file,
one tool version, or one font changes. `tree` is **not** computed from the raw
contents of all packages, so adding a new entry always changes `tree`.

## 4. Updating

1. Install/change dependencies manually (`nimble install`, `pnpm install`,
   `pnpm exec playwright install`).
2. Add the new entry with a temporary `sha256` of `-` (or change `name`/`version`)
   in `deps.lock`.
3. Run `./task deps-check --print`. The output: the `tree <sha256>` line and
   all canonical entries with their recomputed digests. This command does not
   write files.
4. Copy the changed `sha256` values and the `tree` line into `deps.lock`
   (comments and grouping are left alone).
5. `./task deps-check` must pass.

`--print` only reads installed tools; entries that cannot be resolved are
reported on stderr, are not printed, and make the exit code ≠ 0. A
holey output must not be copied silently.

## 5. `deps-check` behaviour

- `./task deps-check` → exit 0 and `deps-check: ok` when every entry matches and
  `tree` is the same.
- Any failure → exit 1, with a `lock:`/`computed:` block per entry that
  differs, then the number of problems. Example:

  ```text
  deps-check: entry differs: mummy
    lock:     mummy 0.4.8 nimble:https://github.com/guzba/mummy 3e3a...
    computed: mummy 0.4.8 nimble:https://github.com/guzba/mummy 91bd...
  deps-check: tree hash differs
    lock:     045c62f915c5e6563a1ecedff545cb50a3999adebcb37a4f6feaa6c3ac334261
    computed: 4ed30fdd0e3f4f2df3ac5e18c1c38bae5b1641b479b94a848707143d7d9716a1
  deps-check: 2 problem(s); update deps.lock (docs/handbook/deps-format.md)
  ```

- An `absent` entry that later becomes installed, or a tool version that goes up (Nim,
  Playwright, browser revision), is reported as drift and **must** be approved
  through a `deps.lock` update. That is the point: gates T-011 and T-072 read
  this file, so version changes must not happen silently.
- A tool that is not installed (for example `node_modules` does not exist yet) fails
  the check for that entry instead of being skipped. If any entry cannot be
  resolved, the `tree` comparison is skipped because a digest over an incomplete
  set of entries is meaningless; the entry failure has already made the exit code ≠ 0.

## 6. Known limits

- A package content digest only proves "the installed directory content matches what is
  pinned", not that the URL in `source` is correct; the URL is taken from `nimblemeta.json`
  the first time it is written to the lock.
- `deps-check` does not check packages that are installed but not recorded in
  `deps.lock` (there is no claim of completeness for all of `pkgs2`). What is guarded is
  every recorded entry.