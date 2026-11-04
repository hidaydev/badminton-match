## Badge catalog and the threshold rule. The catalog is the single source of
## truth for what a player can earn; `db/seeds/achievement_definitions.sql`
## mirrors it row for row so an unknown key never reaches the database.
##
## A badge key encodes the metric and the level reached: `sessions:10`,
## `games:25`, `rank:3`. Tier badges read better with the class name in the key
## (`tier:C`) while their threshold stays the numeric class level.

type
  Category* = enum
    acAttendance = "attendance"
    acVolume = "volume"
    acOpponent = "opponent"
    acTournament = "tournament"
    acTier = "tier"
    acRank = "rank"
    acSocial = "social"

  Metric* = enum
    mcSessions, mcStreak, mcGames, mcWins, mcOpponents, mcPartners,
    mcTournaments, mcTier, mcRank

  Badge* = object
    key*: string
    category*: Category
    metric*: Metric
    threshold*: int

  Facts* = object
    ## Everything the rules need about one player, already aggregated.
    playerId*: string
    sessions*: int
    streak*: int
    games*: int
    wins*: int
    opponents*: int
    partners*: int
    tournaments*: int
    tierLevel*: int
    rank*: int

const tierClasses = [("D", 1), ("D+", 2), ("C", 3), ("C+", 4),
                     ("B", 5), ("B+", 6), ("A", 7), ("A+", 8)]

proc tierLevel*(tier: string): int =
  ## Skill class ordinal, lowest first. An empty or unknown class is zero, so
  ## an unrated player earns no tier badge.
  for (name, level) in tierClasses:
    if name == tier:
      return level
  0

proc metricValue*(facts: Facts, metric: Metric): int =
  case metric
  of mcSessions: facts.sessions
  of mcStreak: facts.streak
  of mcGames: facts.games
  of mcWins: facts.wins
  of mcOpponents: facts.opponents
  of mcPartners: facts.partners
  of mcTournaments: facts.tournaments
  of mcTier: facts.tierLevel
  of mcRank: facts.rank

proc qualifies*(badge: Badge, facts: Facts): bool =
  ## Rank is the one inverted metric: a lower number is the better result.
  if badge.metric == mcRank:
    facts.rank > 0 and facts.rank <= badge.threshold
  else:
    metricValue(facts, badge.metric) >= badge.threshold

proc addLadder(result: var seq[Badge], category: Category, metric: Metric,
               prefix: string, thresholds: openArray[int]) =
  for threshold in thresholds:
    result.add(Badge(key: prefix & ":" & $threshold, category: category,
      metric: metric, threshold: threshold))

proc addTiers(result: var seq[Badge]) =
  ## The lowest seeded class is C: a D player still has a target, and a badge
  ## for simply being on the roster would be noise.
  const floor = 3
  for (name, level) in tierClasses:
    if level >= floor:
      result.add(Badge(key: "tier:" & name, category: acTier, metric: mcTier,
        threshold: level))

proc catalog*(): seq[Badge] =
  ## Thresholds follow the v1 medal ladder (sessions 5..25, games 10..200,
  ## wins 5..200, streak 3..16, partners 5..100, opponents 10..200, rank
  ## 10..1). Tournament counts replace v1's per-event collectible, because the
  ## v2 schema stores one threshold per definition row.
  result.addLadder(acAttendance, mcSessions, "sessions", [5, 10, 15, 20, 25])
  result.addLadder(acAttendance, mcStreak, "streak", [3, 5, 8, 12, 16])
  result.addLadder(acVolume, mcGames, "games", [10, 25, 50, 100, 200])
  result.addLadder(acVolume, mcWins, "wins", [5, 20, 50, 100, 200])
  result.addLadder(acOpponent, mcOpponents, "opponents", [10, 25, 50, 100, 200])
  result.addLadder(acSocial, mcPartners, "partners", [5, 15, 30, 60, 100])
  result.addLadder(acTournament, mcTournaments, "tournaments", [1, 3, 5])
  result.addLadder(acRank, mcRank, "rank", [10, 5, 3, 2, 1])
  result.addTiers()

proc awardedKeys*(facts: Facts): seq[string] =
  ## Every badge the player qualifies for right now, in catalog order.
  for badge in catalog():
    if badge.qualifies(facts):
      result.add(badge.key)
