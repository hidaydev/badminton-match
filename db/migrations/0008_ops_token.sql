-- 0008: bearer tokens for CLI/ops access, separate from browser sessions.
--
-- A CLI cannot carry an HttpOnly cookie, so ops work gets its own credential.
-- Only the hash is stored; the plaintext is printed once by the issuing tool.

create table platform.ops_token (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  token_hash bytea not null,
  created_by uuid references platform.user(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz,
  constraint ops_token_hash_unique unique (token_hash)
);

create index ops_token_expiry_idx on platform.ops_token (expires_at);

-- Tables created after 0004 are not covered by its "all tables" grant.
grant select, insert, update, delete on platform.ops_token to bm2_app;
