-- 0026: the per-game points ledger and the stored score are gone.
--
-- The board projects points from the games on every read, so the ledger had no
-- reader except a second score that ingest fed back into its own opponent
-- weighting. No route exposes that score: the player page takes its points from
-- the board row. Two stored answers for one question also forced every rebuild
-- to replay events in approval order to reproduce them.
--
-- `point_entries` keeps the one thing the ledger was still good for: how many
-- player-game entries an event produced, which the rating sources screen shows
-- and revert/rebuild report back to the operator.
--
-- Destructive on purpose. The rows cannot be recomputed into numbers the board
-- would agree with, and nothing reads them.

alter table rating.events add column point_entries integer not null default 0;

update rating.events e
set point_entries = entries.count
from (select event_id, count(*)::integer as count
      from rating.deltas group by event_id) entries
where entries.event_id = e.id;

drop table rating.deltas;

alter table rating.player_state drop column rating;
