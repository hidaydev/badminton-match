## What changed and why

<!-- Describe the change and the reason for it. -->

## Linked issue

<!-- Reference the issue this PR closes, for example "Closes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor
- [ ] Documentation
- [ ] Build, CI, or deployment change
- [ ] Breaking change

## Verification

- [ ] `./task check` passes
- [ ] `./task test` passes
- [ ] `./task build` passes
- [ ] `./task contract-check` passes (when an HTTP operation changed)
- [ ] `cd apps/web && pnpm check` passes (when the web client changed)
- [ ] `./task e2e` passes (when a screen, router or role boundary changed)
- [ ] `./task coverage` passes (the ratchet, not only the local run)
- [ ] I read `docs/test-plan.md` and this change does not leave an unrecorded gap
- [ ] I did not push to `main` directly
- [ ] New user-visible strings are in `apps/web/src/i18n/en.ts`
