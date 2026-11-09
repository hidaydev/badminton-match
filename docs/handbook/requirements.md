# Requirements register

Every user-visible requirement with the evidence that proves it, or the accepted
risk that says why it is not met. The API contract has its own traceability
(`testdata/authz/matrix.yaml` plus `./task contract-check`); this register links
the product statement to a test a reviewer can run.

Status values: `met` (a test fails when the behaviour disappears), `accepted`
(the behaviour differs on purpose, with a dated decision), `open` (not
implemented and not accepted).

| ID | Requirement | Evidence | Status |
|---|---|---|---|
| REQ-001 | A person signs in with Google and the session cookie is `HttpOnly` | `modules/account/tests/oidc_test.nim`, `apps/api/tests/integration/auth_sessions_http_test.nim` | met |
| REQ-002 | A person without membership sees only the screens their role allows | `modules/account/tests/authz_matrix_test.nim`, `apps/api/tests/security/idor_escalation_test.nim` | met |
| REQ-003 | A host creates a session with courts, participants and a generated schedule | `modules/session/tests/lifecycle_test.nim`, `e2e/session-write.spec.ts` | met |
| REQ-004 | Scores are 0 to 99, a draw is refused, and absent players earn no points | `modules/session/tests/scoring_test.nim`, `modules/session/tests/integration/write_test.nim` | met |
| REQ-005 | Two hosts editing the same game cannot silently overwrite each other | `modules/session/tests/integration/write_test.nim`, `e2e/session-occ.spec.ts` | met |
| REQ-006 | A share link is read-only, unguessable and revocable | `modules/share/tests/crypto_test.nim`, `modules/share/tests/integration/links_test.nim` | met |
| REQ-007 | A share link never expires by itself | `modules/share/tests/integration/links_test.nim` should pin expiry; it does not, see RSK-001 | accepted |
| REQ-008 | A player claim is decided by an admin, one pending claim per player | `modules/player/tests/player_test.nim`, `modules/player/tests/integration/claim_test.nim`, `apps/api/tests/integration/claim_http_test.nim` | met |
| REQ-009 | The points board uses the 12-week window and the best 10 entries | `modules/rating/tests/projection_rules_test.nim`, `modules/rating/tests/rating_test.nim` | met |
| REQ-010 | A tournament scores through a classic group or a bracket and a point ladder | `modules/tournament/tests/classic_test.nim`, `modules/tournament/tests/team_test.nim` | met |
| REQ-011 | Export and scoreboard images come from the same results the screen shows | `modules/tournament/tests/classic_test.nim`, `e2e/scoreboard.spec.ts` | met |
| REQ-012 | The client installs as a PWA and opens offline with the shell cached | `e2e/offline.spec.ts`, `e2e/scoreboard.spec.ts` | met |
| REQ-013 | Every screen measured by axe has zero WCAG A/AA violations | `e2e/a11y.spec.ts`, `e2e/a11y.public.spec.ts` | met |
| REQ-014 | The interface is operable with a keyboard | `e2e/keyboard.spec.ts` | met for the account menu only; see RSK-004 |
| REQ-015 | Sessions are locked automatically after idle time | no automatic lock exists | accepted, see RSK-002 |
| REQ-016 | A fixture game can be replaced on the device that generated it | `modules/session/tests/lifecycle_test.nim` keeps the rule device-local | accepted, see RSK-003 |
| REQ-017 | The interface can be shown in more than one language | `apps/web/src/i18n/en.ts` is the only dictionary | accepted, see RSK-005 |

## Accepted risks

| ID | Risk | Decision | Owner | Review |
|---|---|---|---|---|
| RSK-001 | Share links do not expire; revocation is manual | accepted for 2.0.0: the link is a bearer credential by design, and the code is not derivable; expiry is a product decision | repo owner | 2.1.0 |
| RSK-002 | No automatic session lock after idle time | accepted for 2.0.0: a session is locked by the host who ran it; an automatic rule needs a confirmed window first | repo owner | 2.1.0 |
| RSK-003 | `fix_matches` is device-local and does not sync | accepted for 2.0.0: the fixture rules live in the browser generator, so a second device cannot reproduce the seed | repo owner | 2.1.0 |
| RSK-004 | Keyboard coverage is one disclosure, not a full flow | accepted for 2.0.0; see `docs/ops/accessibility.md` | repo owner | 2.1.0 |
| RSK-005 | The product is single-locale and part of the legacy tree bypasses the dictionary | accepted for 2.0.0; see `docs/handbook/product-overview.md` | repo owner | 2.1.0 |

The register is checked by `./task docs-check`: a referenced evidence file that
does not exist fails the gate. A requirement whose test was deleted is a
requirement without evidence, which is the same as unmet.
