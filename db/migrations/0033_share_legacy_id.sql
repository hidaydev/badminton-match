-- 0033: a share link minted before the code era keeps answering by session id.
--
-- Version one handed out `/s/{sessionId}`. `resolve` still accepts that shape
-- for any uuid-shaped input, and it looked up the session's live row, so
-- rotating a link handed the same access to whoever kept the old session id.
-- The shortcut is now per row: only links that existed before codes carry it.
--
-- Every row present right now predates the change, so the backfill marks them
-- all. `issue()` omits the column and gets the default, so a rotated or new
-- link answers by its code only.
--
-- Guarded so a replay does nothing: once the column exists, rows created since
-- (all `false` by default) must not be flipped back to `true`.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'session' and table_name = 'links'
      and column_name = 'legacy_id_ok'
  ) then
    alter table session.links
      add column legacy_id_ok boolean not null default false;
    update session.links set legacy_id_ok = true;
  end if;
end $$;