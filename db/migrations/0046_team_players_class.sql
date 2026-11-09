-- 0046: a team sheet uses the same class vocabulary as the player tier.
--
-- `player.players.tier` accepts the eight values `D, D+, C, C+, B, B+, A, A+`,
-- while `tournament.team_players.cls` stopped at `C`. A D-tier player could not
-- be written on a team at all. `cls` stays a snapshot of the class entered on
-- the sheet, but it now accepts every tier the rating ladder can produce.
alter table tournament.team_players
  drop constraint team_players_cls_check,
  add constraint team_players_cls_check
    check (cls in ('D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+'));
