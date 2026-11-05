import std/[options, os, sets, strutils, unittest]
import ../domain/achievement

proc seedPath(): string =
  currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "db" / "seeds" / "achievement_definitions.sql"

suite "achievement catalog":
  let badges = catalog()

  test "keys are unique":
    var seen = initHashSet[string]()
    for badge in badges:
      check badge.key notin seen
      seen.incl(badge.key)

  test "every key is seeded":
    let seed = readFile(seedPath())
    check seed.len > 0
    for badge in badges:
      check seed.contains("('" & badge.key & "'")

  test "each seeded category is reachable":
    var categories = initHashSet[Category]()
    for badge in badges:
      categories.incl(badge.category)
    check categories == toHashSet([acAttendance, acVolume, acOpponent,
      acTournament, acTier, acRank, acSocial])

  test "ladders ascend and rank descends":
    for metric in [mcSessions, mcStreak, mcGames, mcWins, mcOpponents,
                   mcPartners, mcTournaments, mcTier]:
      var previous = 0
      for badge in badges:
        if badge.metric == metric:
          check badge.threshold > previous
          previous = badge.threshold
    var lower = 100
    for badge in badges:
      if badge.metric == mcRank:
        check badge.threshold < lower
        lower = badge.threshold

  test "tier badges start at C":
    var levels: seq[int] = @[]
    for badge in badges:
      if badge.metric == mcTier:
        levels.add(badge.threshold)
    check levels == @[3, 4, 5, 6, 7, 8]
    check tierLevel("D") == 1
    check tierLevel("C+") == 4
    check tierLevel("A+") == 8
    check tierLevel("") == 0
    check tierLevel("Z") == 0

  test "a rank-streak run counts the rungs it has passed":
    let ladder = @[3, 5, 8, 12, 16]
    check ladderLevel("rank_streak", 2, ladder) == 0
    check ladderLevel("rank_streak", 3, ladder) == 1
    check ladderLevel("rank_streak", 11, ladder) == 3
    check ladderLevel("rank_streak", 16, ladder) == 5
    check ladderLevel("rank_streak", 99, ladder) == 5
    check nextTarget("rank_streak", 11, ladder) == some(12)
    check nextTarget("rank_streak", 16, ladder).isNone
    check nextTarget("rank_streak", 99, ladder).isNone

  test "rungs are matched exactly outside a streak":
    check ladderLevel("sessions", 8, @[5, 10, 15]) == 0
    check ladderLevel("sessions", 10, @[5, 10, 15]) == 2
    check ladderLevel("tier", 5, @[3, 4, 5]) == 0
    check nextTarget("sessions", 5, @[5, 10, 15]) == some(10)
    check nextTarget("sessions", 15, @[5, 10, 15]).isNone
    check nextTarget("sessions", 7, @[5, 10, 15]).isNone
    # Rank runs downward, so the ladder is reversed before the next rung.
    check ladderFor("rank", @[1, 5, 10]) == @[10, 5, 1]
    check nextTarget("rank", 5, @[10, 5, 1]) == some(1)
    check ladderFor("rank_streak", @[16, 3, 12]) == @[3, 12, 16]

  test "every catalogue row reads as English copy":
    ## Walks every switch arm in the title/detail copy, so a new key cannot
    ## ship without words.
    for badge in catalog():
      check achievementTitle(badge.key, $badge.category,
        badge.threshold).len > 0
      check achievementDetail(badge.key, $badge.category,
        badge.threshold).len > 0

  test "rank-streak copy and short ladders":
    check achievementTitle("rank_streak:11", "rank", 11) == "Rank streak 11"
    check achievementDetail("rank_streak:11", "rank", 11) ==
      "Hold a ranked position for 11 sessions in a row."
    check ladderLevel("sessions", 5, @[5]) == 0
    check nextTarget("sessions", 5, @[5]).isNone
    check nextTarget("tier", 3, @[3, 4]).isNone

  test "an unknown family still gets readable copy":
    check keyMetric("mystery") == "mystery"
    check keySuffix("mystery") == ""
    check achievementTitle("mystery:3", "social", 3) == "Social 3"
    check achievementDetail("mystery:3", "social", 3) == "Reach 3 social."

suite "achievement rules":
  test "a threshold is inclusive":
    let facts = Facts(playerId: "p", sessions: 5)
    for badge in catalog():
      if badge.key == "sessions:5":
        check badge.qualifies(facts)
      if badge.key == "sessions:10":
        check not badge.qualifies(facts)

  test "rank is inverted and zero never qualifies":
    var facts = Facts(playerId: "p", rank: 3)
    for badge in catalog():
      if badge.key == "rank:3":
        check badge.qualifies(facts)
      if badge.key == "rank:2":
        check not badge.qualifies(facts)
    facts.rank = 0
    for badge in catalog():
      if badge.metric == mcRank:
        check not badge.qualifies(facts)

  test "an empty player earns nothing":
    check awardedKeys(Facts(playerId: "p")).len == 0

  test "a strong player earns one badge per crossed threshold":
    let facts = Facts(playerId: "p", sessions: 12, streak: 5, games: 30,
      wins: 6, opponents: 12, partners: 5, tournaments: 1, tierLevel: 4,
      rank: 2)
    let keys = awardedKeys(facts)
    for key in ["sessions:5", "sessions:10", "streak:3", "streak:5",
                "games:10", "games:25", "wins:5", "opponents:10",
                "partners:5", "tournaments:1", "tier:C", "tier:C+",
                "rank:10", "rank:5", "rank:3", "rank:2"]:
      check key in keys
    for key in ["sessions:15", "games:50", "wins:20", "opponents:25",
                "rank:1", "tier:B"]:
      check key notin keys
