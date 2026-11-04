-- Badge catalog. Mirrors modules/achievement/domain/achievement.nim row for
-- row; a key that is absent here can never be earned, because
-- achievement.earned references achievement.definitions.
--
-- Thresholds follow the v1 medal ladder. Categories v1 had but v2 cannot
-- reach are deliberately absent: `rating` (v2 keeps relative points, not an
-- absolute rating) and `season` (the season cycle was retired before v2).

insert into achievement.definitions (key, category, threshold) values
  ('sessions:5',    'attendance', 5),
  ('sessions:10',   'attendance', 10),
  ('sessions:15',   'attendance', 15),
  ('sessions:20',   'attendance', 20),
  ('sessions:25',   'attendance', 25),
  ('streak:3',      'attendance', 3),
  ('streak:5',      'attendance', 5),
  ('streak:8',      'attendance', 8),
  ('streak:12',     'attendance', 12),
  ('streak:16',     'attendance', 16),
  ('games:10',      'volume', 10),
  ('games:25',      'volume', 25),
  ('games:50',      'volume', 50),
  ('games:100',     'volume', 100),
  ('games:200',     'volume', 200),
  ('wins:5',        'volume', 5),
  ('wins:20',       'volume', 20),
  ('wins:50',       'volume', 50),
  ('wins:100',      'volume', 100),
  ('wins:200',      'volume', 200),
  ('opponents:10',  'opponent', 10),
  ('opponents:25',  'opponent', 25),
  ('opponents:50',  'opponent', 50),
  ('opponents:100', 'opponent', 100),
  ('opponents:200', 'opponent', 200),
  ('partners:5',    'social', 5),
  ('partners:15',   'social', 15),
  ('partners:30',   'social', 30),
  ('partners:60',   'social', 60),
  ('partners:100',  'social', 100),
  ('tournaments:1', 'tournament', 1),
  ('tournaments:3', 'tournament', 3),
  ('tournaments:5', 'tournament', 5),
  ('rank:10',       'rank', 10),
  ('rank:5',        'rank', 5),
  ('rank:3',        'rank', 3),
  ('rank:2',        'rank', 2),
  ('rank:1',        'rank', 1),
  ('tier:C',        'tier', 3),
  ('tier:C+',       'tier', 4),
  ('tier:B',        'tier', 5),
  ('tier:B+',       'tier', 6),
  ('tier:A',        'tier', 7),
  ('tier:A+',       'tier', 8)
on conflict (key) do nothing;
