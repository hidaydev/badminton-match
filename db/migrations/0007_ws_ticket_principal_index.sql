-- 0007: ws ticket lookup paths used by revocation and janitor sweeps.
--
-- Revocation deletes by principal (`user_id`) and, for shared links, by
-- (`channel_kind`, `channel_id`); both are full scans without these.

create index if not exists ws_ticket_user_idx
  on platform.ws_ticket (user_id);

create index if not exists ws_ticket_channel_idx
  on platform.ws_ticket (channel_kind, channel_id);
