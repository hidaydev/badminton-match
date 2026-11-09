-- 0045: a badge key is either catalogued or one of the two v1 families.
--
-- `0019` dropped the foreign key to `achievement.definitions` so the imported
-- per-event medals (`tournament:<uuid>`) and the rank-streak family
-- (`rank_streak:<n>`) could stay. That left `achievement_key` unvalidated: a
-- typo looked exactly like an imported medal, and no shelf query renders either.
-- The two imported families are accepted by pattern; everything else must name
-- a catalog row.
create or replace function achievement.validate_earned_key() returns trigger
language plpgsql as $$
begin
  if new.achievement_key like 'tournament:%'
     or new.achievement_key like 'rank_streak:%' then
    return new;
  end if;
  if exists (select 1 from achievement.definitions d
              where d.key = new.achievement_key) then
    return new;
  end if;
  raise exception 'achievement.earned: unknown key %', new.achievement_key
    using errcode = '23514';
end;
$$;

create trigger earned_key_known
  before insert or update of achievement_key on achievement.earned
  for each row execute function achievement.validate_earned_key();
