-- 0021: the tier ladder becomes v1's class ranges.
--
-- The ranking board weights a game by the opponents' sticky tier, and v1
-- derived a tier's strength from the middle of its range (`class_bands`).
-- A floor-only ladder cannot express that: D was anchored at 0, so its
-- strength sat at 500 while v1's D sat at 1100. The ladder is now the eight
-- ranges themselves, with a null max for the open top band.

update platform.config
set value = '[{"tier":"D","min":1000,"max":1199},{"tier":"D+","min":1200,"max":1299},{"tier":"C","min":1300,"max":1499},{"tier":"C+","min":1500,"max":1599},{"tier":"B","min":1600,"max":1799},{"tier":"B+","min":1800,"max":1899},{"tier":"A","min":1900,"max":2099},{"tier":"A+","min":2100,"max":null}]',
    description = 'Eight-tier class bands and their ranges'
where key = 'rating.tier_bands';
