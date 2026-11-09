# QAE-05: one anonymous request, one OAuth flow row

Session of 2026-11-10 on `w3/qae` (based on `0e3000c1`), charter
`docs/qa/charter-http-boundary.md`. Scratch database `bm2_w3qa`, release build on
8098, no session cookie.

## What one caller writes

```
psql -d bm2_w3qa -tAc "select count(*) from auth.oauth_flows"
# 0

for i in $(seq 1 30); do
  curl -sS -o /dev/null -w '%{http_code} ' -X POST \
    -H 'Origin: http://localhost:5173' -H 'Content-Type: application/json' \
    --data '{}' http://127.0.0.1:8098/auth/start
done
# 200 x 30

psql -d bm2_w3qa -tAc "select count(*) from auth.oauth_flows"
# 30
```

One request, one row. The route never asks for a body and never asks who is
calling, so the count is the same whether the caller is a browser starting a
login or a script.

## The budget that answers first

330 requests, each with a different forged `majadu_session` value from the same
address:

```
statuses: {'200': 300, '429': 30}
first 429 at request: 301
```

```
psql -d bm2_w3qa -tAc "select count(*) from auth.oauth_flows"
# 330
```

The address budget stops the sweep at the configured 300 per minute
(`security.rate_limit_per_minute`) even though every request carried a fresh
cookie. The 30 rejected requests wrote nothing, which is the second half of the
QAE-01 fix holding: the pre-limit answers before `startAuth` runs.

So the write rate per address is 300 rows per minute, not unbounded.

## The bound that does not exist

`auth.oauth_flows` has no address column (`db/migrations/0004_platform.sql`), so
a per-address cap on pending flows cannot be expressed today. The only reclaim
is expiry: `auth.flow_ttl_minutes` is 10, and the janitor that deletes by
`expires_at` runs once a day (`ops/systemd/majadu-janitor.timer`). A single
address therefore leaves up to 300 rows per minute it is used, and the table
holds them for up to a day, not for the ten minutes the TTL suggests.

With more than one address the aggregate is not bounded by anything. The audit
measured 634 rows after 660 requests, which this session reproduces at the same
ratio.

## DoD status

1. "the auth-start budget is keyed on the address, not the cookie":
   **satisfied**. The sweep above never got past 300 with a fresh cookie each
   time, because `requestIdentity` only trusts a cookie the database confirmed.
   `apps/api/tests/integration/security/ratelimit_test.nim` holds it:
   - "random unknown session cookies stay in the address bucket"
   - "minting share buckets cannot reset the exhausted address budget"
2. "a cap on pending flows per address exists and is tested": **not satisfied**.
   The cap needs a column, a store read and a refusal path, so it belongs to
   `db/` and `apps/api`, not to this tree. What is missing is a `delete` of the
   caller's oldest pending flow, or a count check before the insert, inside
   `startAuth`.

## What this session changes

Nothing in the product. The finding stays open against `apps/api` and `db/`, and
this note is the evidence a fix has to answer: 300 rows per address per minute,
a daily purge, and no per-address ceiling. No test is added, because a test
asserting the cap would fail until the cap exists; the address-budget half is
already covered by the suite named above.
