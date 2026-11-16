# CRITICAL_ENVIRONMENT_RULES: Token Economy & Release Rules

## Token Economy
- Standalone Codex CLI cannot auto-intercept raw shell queries. 
- You MUST manually prepend `rtk` to any command that generates heavy text outputs to prevent polluting the context window.
- MANDATORY MANDATE: Always substitute naked commands with `rtk <command>`.
- CORRECT EXAMPLES: Use `rtk git status`, `rtk git diff`, `rtk grep -rn "search"`, and `rtk pnpm check` (repo is pnpm-only, no `npm`/`package-lock.json`).

## Versioning & Release SOP for Agents
- **Dispatcher**: Single command runner `./task` governs the release lifecycle (`./task release` dry run, `./task release --apply`).
- **Bump Logic**: SemVer 2.0 derived from Conventional Commits (`tools/release`). A release requires at least one `feat` (minor) or `fix`/`perf` (patch) commit since the last tag.
- **Automated Sync**: `./task release --apply` writes `VERSION`, `CHANGELOG.md`, `.cache/release/v<version>.md`, and updates the parity version pin (`testdata/parity/v2/version.json` + `MANIFEST.sha256`).
- **Commit Format**: `chore(release): v<version>`
- **Tagging**: SSH-signed tag matching `v<version>` verified against `.github/allowed_signers`.
- **Push Sequence (CRITICAL)**:
  1. `git push origin refs/tags/v<version>` (triggers `release.yml` to build and cosign the GHCR container image)
  2. `git push origin HEAD:main` (triggers VPS deploy webhook, which polls and verifies the signed container image)
  Never push `main` before the tag; otherwise the deploy runner times out waiting for an image that has not started building.
