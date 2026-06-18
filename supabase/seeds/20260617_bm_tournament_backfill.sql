insert into bm.tournaments (
  id,
  name,
  event_date,
  snapshot,
  updated_at
)
select
  t.id,
  t.name,
  t.event_date,
  t.snapshot,
  t.updated_at
from badminton_match.tournaments t
on conflict (id) do update
  set name = excluded.name,
      event_date = excluded.event_date,
      snapshot = excluded.snapshot,
      updated_at = excluded.updated_at;
