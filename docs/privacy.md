# Privacy

This application records the results of community badminton matches. This document
states what data is stored, on what basis, for how long, and what happens when
someone asks for their account to be closed. Written for operators and players,
not for auditors.

## 1. Basis for processing

- **Performance of community activity.** Player names, partners, scores, and
  schedules are recorded because without them the community has no match history
  and no ranking. Players who do not want to be recorded do not need to be
  registered.
- **Consent at login.** Who may log in is determined by Google login. Platform
  owners and community administrators use that account to manage data; players
  use it to claim their own player row.
- There are no advertising profiles, no cross-site tracking, and no selling of
  data to third parties.

## 2. Data stored

| Data | Form | Notes |
|---|---|---|
| Google identity | `google_sub` (subject id) | Not email, not display name. Enough to recognise the same login. |
| Email | `email_hash` (SHA-256) | Raw email is not stored, including on invitations. |
| Display name | text | Taken from the Google account at login. |
| Membership | role per community (`admin`/`host`/`member`) | One user can have different roles in different communities. |
| Player | canonical name, aliases, gender, level | Owned by the community, not by the account. Can exist without an account. |
| Matches | session, schedule, score, attendance, tournament | History of community activity. |
| Ranking | events (number of entries), played/won/lost counts, snapshots | Derived from matches; the per-game points ledger is not stored. |
| Audit | action, actor, target, reason | No raw email, no IP, no link code. |
| Sessions and links | session cookie, link code hash | The link code is stored as hash + ciphertext, not plaintext. |

What is **not** stored: passwords (login is through Google), IP addresses, user
agents, navigation history, and raw email.

There is only one cookie: the `HttpOnly` session cookie. There are no tokens in
JavaScript, no `localStorage`, and no third-party cookies. Share links
(`/s/<code>`) can be opened without a cookie and only show the content of the
session being shared.

## 3. Retention

| Data | Lifetime | Managed by |
|---|---|---|
| OAuth flows, idempotency keys, outbox, WebSocket tickets | `janitor.retention_days` (default 30 days) | `./task janitor`, application role |
| Revoked links | follows the janitor | `./task janitor` |
| Audit | `audit.retention_days` (default 365 days) | `./task audit-retention`, `bm2_owner` role |
| Login sessions | idle `session.idle_days` (7 days), absolute `session.absolute_days` (30 days) | application |
| Scores, tournaments, rankings | not deleted automatically | community |

Retention numbers are configuration (`platform.config`), not code constants, and
can be overridden per community only towards a shorter or stricter value.

## 4. Account closure

`./task account anonymize --sub <google-sub> --actor <actor-sub> [--reason <text>]`
runs one transaction:

1. All claims owned by the account are closed with status `released` (their
   history stays).
2. The linked player row is released (`user_id` becomes empty), its data stays.
3. Community memberships (`community.membership`) owned by the account are
   deleted in every community the account has ever touched, including communities
   it only joined through membership, with no claim or linked player.
4. Login sessions and WebSocket tickets are deleted.
5. `google_sub`, `email_hash`, and `display_name` are rewritten into an anonymous
   identity, so logging in with the same Google account no longer finds this user.

Membership is deleted, not anonymised, because it is only a link from account to
community and stores no match history. A consequence operators need to know: if
the closed account is the **only admin** of a community, that community is left
without an admin and must be given a new admin manually.

What is **kept**: scores, tournaments, rating history (events and snapshots), and
audit. Match history belongs to the player and the community, not to the account;
deleting it would change other players' rankings. Audit stays because it records
administrative actions, not identity.

A claim that has been closed cannot be reopened with the same login, because its
Google identity is no longer connected.

## 5. Data leaks

Report through a GitHub private security advisory:

https://github.com/hidaydev/badminton-match/security/advisories/new

Do not open a public issue, and do not include email, session cookies, or link
codes in the report. For an incident that has already happened, record it with
the five-field format in `docs/ops/operations.md` and store it in
`.local/incidents/`.

## 6. Changes to this document

This document is part of the code: a change that alters what is stored or for how
long must change this file in the same commit.