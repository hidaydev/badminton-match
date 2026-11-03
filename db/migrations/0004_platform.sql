-- 0004: platform registry, cutover state, auth flows, sessions, audit, outbox.

create schema if not exists auth;
create schema if not exists account;

create table platform.config (
  key text primary key,
  value_type text not null,
  value jsonb not null,
  min_value numeric,
  max_value numeric,
  scope text not null,
  description text not null default '',
  since_version text not null default '2.0.0',
  constraint config_type_check check (value_type in ('int', 'decimal', 'bool', 'string', 'json')),
  constraint config_scope_check check (scope in ('platform', 'community')),
  constraint config_bounds_check check (min_value is null or max_value is null or min_value <= max_value)
);

create table platform.config_version (
  id boolean primary key default true,
  version bigint not null default 0,
  constraint config_version_singleton check (id)
);
insert into platform.config_version (id, version) values (true, 0) on conflict do nothing;

create table platform.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references platform.user(id) on delete cascade,
  key text not null,
  body_hash text not null,
  status_code integer,
  response jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint idempotency_user_key_unique unique (user_id, key)
);

create index idempotency_expiry_idx on platform.idempotency_keys (expires_at);

create table platform.import_row_map (
  community_id uuid not null references platform.community(id) on delete cascade,
  source_table text not null,
  source_key text not null,
  target_id uuid not null,
  imported_at timestamptz not null default now(),
  primary key (community_id, source_table, source_key)
);

create table platform.ws_ticket (
  id uuid primary key default gen_random_uuid(),
  token_hash bytea not null,
  channel_kind text not null,
  channel_id uuid not null,
  user_id uuid references platform.user(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  constraint ws_ticket_token_unique unique (token_hash),
  constraint ws_ticket_channel_kind_check check (channel_kind in ('session', 'share')),
  constraint ws_ticket_share_anonymous check (channel_kind = 'share' or user_id is not null)
);

create index ws_ticket_expiry_idx on platform.ws_ticket (expires_at);

create table platform.cutover_state (
  id boolean primary key default true,
  snapshot_sha256 text,
  snapshot_taken_at timestamptz,
  etl_completed_at timestamptz,
  completed_at timestamptz,
  constraint cutover_state_singleton check (id)
);

create table auth.oauth_flows (
  id uuid primary key default gen_random_uuid(),
  state_hash bytea not null,
  nonce_hash bytea not null,
  code_verifier_enc bytea not null,
  return_to text not null default '/',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint oauth_flows_state_unique unique (state_hash)
);

create index oauth_flows_expiry_idx on auth.oauth_flows (expires_at);

create table account.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references platform.user(id) on delete cascade,
  token_hash bytea not null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  absolute_expires_at timestamptz not null,
  revoked_at timestamptz,
  constraint sessions_token_unique unique (token_hash)
);

create index account_sessions_user_idx on account.sessions (user_id);

create table account.audit (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  actor_id uuid,
  actor_role text not null,
  community_id uuid,
  action text not null,
  target_kind text not null,
  target_id text not null,
  result text not null,
  reason text,
  request_id text not null,
  before jsonb,
  after jsonb,
  constraint audit_result_check check (result in ('allow', 'deny', 'error'))
);

create index audit_community_time_idx on account.audit (community_id, occurred_at desc);
create index audit_actor_time_idx on account.audit (actor_id, occurred_at desc);

create table platform.outbox (
  id uuid primary key default gen_random_uuid(),
  topic text not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create index outbox_pending_idx on platform.outbox (created_at) where processed_at is null;

grant usage on schema auth, account to bm2_app;
grant select, insert, update, delete on all tables in schema platform to bm2_app;
grant select, insert, update, delete on all tables in schema auth to bm2_app;
grant select, insert, update, delete on all tables in schema account to bm2_app;

-- Audit is append-only for the application (D16).
revoke update, delete on account.audit from bm2_app;
grant select, insert on account.audit to bm2_app;
