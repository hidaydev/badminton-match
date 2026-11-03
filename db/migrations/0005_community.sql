-- 0005: membership, invites, join requests and per-community settings.

create schema if not exists community;

create table community.membership (
  community_id uuid not null references platform.community(id) on delete cascade,
  user_id uuid not null references platform.user(id) on delete cascade,
  role text not null default 'member',
  created_at timestamptz not null default now(),
  primary key (community_id, user_id),
  constraint membership_role_check check (role in ('member', 'host', 'admin'))
);

create index membership_user_idx on community.membership (user_id);

create table community.invite (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete cascade,
  token_hash bytea not null,
  email_hash text not null,
  role text not null default 'member',
  created_by uuid references platform.user(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  accepted_at timestamptz,
  constraint invite_token_unique unique (token_hash),
  constraint invite_role_check check (role in ('member', 'host', 'admin'))
);

create index invite_community_idx on community.invite (community_id, created_at desc);

create table community.join_request (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete cascade,
  user_id uuid not null references platform.user(id) on delete cascade,
  status text not null default 'pending',
  decided_at timestamptz,
  decided_by uuid references platform.user(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint join_request_status_check check (status in ('pending', 'approved', 'rejected')),
  constraint join_request_decision_check check ((status = 'pending') = (decided_at is null))
);

create unique index join_request_one_pending
  on community.join_request (community_id, user_id) where status = 'pending';

create index join_request_community_idx
  on community.join_request (community_id, created_at desc);

create table community.settings (
  community_id uuid primary key references platform.community(id) on delete cascade,
  values jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

grant usage on schema community to bm2_app;
grant select, insert, update, delete on all tables in schema community to bm2_app;
