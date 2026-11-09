-- 0047: a community's timezone is a real IANA zone, and a court may end after
-- midnight.
--
-- A session stores a local `date` plus `time` columns, so the zone is what gives
-- those values meaning. The old check only rejected blank text, and
-- `Asia/Jakrta` was accepted: every conversion then depended on whatever
-- fallback the caller happened to have. The trigger reads `pg_timezone_names`,
-- which a CHECK cannot do.
--
-- Court times were forced to `end_time > start_time`, so a 22:00 to 01:00 court
-- could not be represented at all. An end at or before the start now means "the
-- next day"; the pair is still a local wall-clock interval.
create or replace function platform.validate_timezone() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'unknown timezone: %', new.timezone using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger community_timezone_known
  before insert or update of timezone on platform.community
  for each row execute function platform.validate_timezone();

alter table session.courts drop constraint courts_time_range;
alter table session.courts
  add constraint courts_time_order check (end_time <> start_time);
