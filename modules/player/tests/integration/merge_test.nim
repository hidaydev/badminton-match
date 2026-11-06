import std/[options, os, unittest]
import db/db
import ../../merge

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc addPlayer(db: Db, communityId, name: string): string =
  db.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

proc countRows(db: Db, communityId, table: string): string =
  db.queryOne(
    "select count(*)::int as total from " & table &
      " where community_id = $1::uuid",
    @[textParam(communityId)]).get.get("total")

suite "player merge":
  var db: Db
  var communityId, actorId: string
  var targetId, sourceId: string
  var aliasBefore, deltaBefore, snapshotBefore, earnedBefore: string

  proc cleanup() =
    ## FK-safe order for every row this suite may leave behind.
    for statement in [
      """delete from session.sessions where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from tournament.matches where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from tournament.pairs where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from tournament.tournaments where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from achievement.earned where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from rating.events where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from rating.snapshots where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from rating.player_state where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from player.claims where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from player.aliases where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from player.merge_log where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      """delete from player.players where community_id in
           (select id from platform.community where slug = 'merge-test')""",
      "delete from platform.community where slug = 'merge-test'",
      "delete from platform.user where google_sub = 'merge-test-actor'"]:
      discard db.execUpdate(statement)

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    cleanup()
    actorId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('merge-test-actor', 'merge-test-hash', 'Merger') returning id""")
      .get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('merge-test', 'Merge Test', 'Asia/Jakarta') returning id""")
      .get.get("id")

    targetId = addPlayer(db, communityId, "Merge Target")
    sourceId = addPlayer(db, communityId, "Merge Source")
    let partnerA = addPlayer(db, communityId, "Merge Partner A")
    let partnerB = addPlayer(db, communityId, "Merge Partner B")

    discard db.execUpdate(
      """insert into player.aliases (community_id, player_id, alias)
         values ($1::uuid, $2::uuid, 'Merge Source Alias')""",
      @[textParam(communityId), textParam(sourceId)])

    let eventId = db.queryOne(
      """insert into rating.events (community_id, local_date, event_type)
         values ($1::uuid, '2026-11-01', 'manual') returning id""",
      @[textParam(communityId)]).get.get("id")
    discard db.execUpdate(
      """insert into rating.snapshots
           (community_id, player_id, taken_on, rating)
         values ($1::uuid, $2::uuid, '2026-11-01', 1500)""",
      @[textParam(communityId), textParam(sourceId)])
    discard db.execUpdate(
      """insert into achievement.definitions (key, category, threshold)
         values ('sessions:5', 'attendance', 5) on conflict do nothing""")
    discard db.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key)
         values ($1::uuid, $2::uuid, 'sessions:5')""",
      @[textParam(communityId), textParam(sourceId)])

    # The pair naming both players would become a self-pair, but a match still
    # refers to it, so the merge must be refused.
    let tournamentId = db.queryOne(
      """insert into tournament.tournaments (community_id, name, status)
         values ($1::uuid, 'Merge Cup', 'active') returning id""",
      @[textParam(communityId)]).get.get("id")
    let selfPair = db.queryOne(
      """insert into tournament.pairs
           (community_id, tournament_id, display_name, player_a_id, player_b_id)
         values ($1::uuid, $2::uuid, 'Source/Target', $3::uuid, $4::uuid)
         returning id""",
      @[textParam(communityId), textParam(tournamentId), textParam(sourceId),
        textParam(targetId)]).get.get("id")
    let otherPair = db.queryOne(
      """insert into tournament.pairs
           (community_id, tournament_id, display_name, player_a_id, player_b_id)
         values ($1::uuid, $2::uuid, 'Partners', $3::uuid, $4::uuid)
         returning id""",
      @[textParam(communityId), textParam(tournamentId), textParam(partnerA),
        textParam(partnerB)]).get.get("id")
    discard db.execUpdate(
      """insert into tournament.matches
           (community_id, tournament_id, round_no, pair_a_id, pair_b_id)
         values ($1::uuid, $2::uuid, 1, $3::uuid, $4::uuid)""",
      @[textParam(communityId), textParam(tournamentId), textParam(selfPair),
        textParam(otherPair)])

    aliasBefore = countRows(db, communityId, "player.aliases")
    snapshotBefore = countRows(db, communityId, "rating.snapshots")
    earnedBefore = countRows(db, communityId, "achievement.earned")

  teardown:
    cleanup()
    db.close()

  proc playerId(name: string): string =
    db.queryOne(
      """select id from player.players
         where community_id = $1::uuid and canonical_name = $2""",
      @[textParam(communityId), textParam(name)]).get.get("id")

  proc unblockMerge() =
    ## The setup's self-pair and its match refuse every merge; drop them.
    discard db.execUpdate(
      """delete from tournament.matches where community_id = $1::uuid""",
      @[textParam(communityId)])
    discard db.execUpdate(
      """delete from tournament.pairs where community_id = $1::uuid
           and display_name = 'Source/Target'""",
      @[textParam(communityId)])

  proc addSession(title: string): string =
    db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, status, source)
         values ($1::uuid, $2, '2026-11-02', 'draft', 'manual') returning id""",
      @[textParam(communityId), textParam(title)]).get.get("id")

  proc addParticipant(sessionId, playerId: string) =
    discard db.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(playerId)])

  proc addGame(sessionId: string, roundNo, courtNo: int, sideA, sideB: string) =
    discard db.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, side_a1, side_b1)
         values ($1::uuid, $2::uuid, $3, $4, $5::uuid, $6::uuid)""",
      @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
        intParam(courtNo.int64), textParam(sideA), textParam(sideB)])

  proc gamesIn(sessionId: string): string =
    db.queryOne(
      """select count(*)::int as total from session.games
         where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("total")

  test "a self-pair used by a match refuses the merge without writing":
    let outcome = merge(db, communityId, targetId, sourceId, actorId)
    check outcome.error == mePairInUse

    check countRows(db, communityId, "player.aliases") == aliasBefore
    check countRows(db, communityId, "rating.snapshots") == snapshotBefore
    check countRows(db, communityId, "achievement.earned") == earnedBefore
    check countRows(db, communityId, "player.merge_log") == "0"
    check db.queryOne(
      "select id from player.players where id = $1::uuid",
      @[textParam(sourceId)]).isSome

  test "a moved pair's display name follows the new player":
    # The setup's self-pair and its match block the merge; drop them and give
    # the source a normal pair so the move succeeds.
    unblockMerge()
    let partnerId = playerId("Merge Partner A")
    let pairId = db.queryOne(
      """insert into tournament.pairs
           (community_id, tournament_id, display_name, player_a_id, player_b_id)
         select $1::uuid, id, 'Merge Source & Merge Partner A', $2::uuid, $3::uuid
         from tournament.tournaments where community_id = $1::uuid
         returning id""",
      @[textParam(communityId), textParam(sourceId),
        textParam(partnerId)]).get.get("id")
    let outcome = merge(db, communityId, targetId, sourceId, actorId)
    check outcome.error == meOk
    check outcome.result.pairsMoved == 1
    let moved = db.queryOne(
      """select display_name from tournament.pairs
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(pairId)]).get.get("display_name")
    # The bracket would otherwise still name the player that no longer exists.
    check moved == "Merge Target & Merge Partner A"

  test "session history naming the source moves to the target":
    block:
      unblockMerge()
      let teammateA = playerId("Merge Partner A")
      let teammateB = playerId("Merge Partner B")
      # Shared session: the two players played separate games, so both already
      # own a participant row and only the source's duplicate has to go.
      let shared = addSession("Separate games")
      for player in [sourceId, targetId, teammateA, teammateB]:
        addParticipant(shared, player)
      addGame(shared, 0, 0, sourceId, teammateA)
      addGame(shared, 0, 1, targetId, teammateB)
      discard db.execUpdate(
        """insert into session.game_skips
             (community_id, session_id, round_no, court_no, player_id)
           values ($1::uuid, $2::uuid, 0, 1, $3::uuid)""",
        @[textParam(communityId), textParam(shared), textParam(sourceId)])
      # Source-only session: the participant row itself changes owner.
      let alone = addSession("Source only")
      addParticipant(alone, sourceId)
      addParticipant(alone, teammateA)
      addGame(alone, 0, 0, sourceId, teammateA)

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      check outcome.error == meOk
      check outcome.result.sessionsMoved == 1
      check outcome.result.gamesMoved == 2
      check outcome.result.skipsMoved == 1

      check db.queryOne(
        "select id from player.players where id = $1::uuid",
        @[textParam(sourceId)]).isNone
      check countRows(db, communityId, "session.participants") == "5"
      check db.queryOne(
        """select count(*)::int as total from session.participants
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)]).get.get("total") == "0"
      check db.queryOne(
        """select count(*)::int as total from session.participants
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(targetId)]).get.get("total") == "2"
      check gamesIn(alone) == "1"
      check db.queryOne(
        """select side_a1 from session.games
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(alone)]).get.get("side_a1") == targetId
      check db.queryOne(
        """select count(*)::int as total from session.games
           where community_id = $1::uuid
             and $2::uuid in (side_a1, side_a2, side_b1, side_b2)""",
        @[textParam(communityId), textParam(sourceId)]).get.get("total") == "0"
      check db.queryOne(
        """select count(*)::int as total from session.games
           where community_id = $1::uuid
             and $2::uuid in (side_a1, side_a2, side_b1, side_b2)""",
        @[textParam(communityId), textParam(targetId)]).get.get("total") == "3"
      check db.queryOne(
        """select count(*)::int as total from session.game_skips
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(targetId)]).get.get("total") == "1"

  test "both players in the same game refuse the merge without writing":
    block:
      unblockMerge()
      let teammateA = playerId("Merge Partner A")
      let sessionId = addSession("Self match")
      for player in [sourceId, targetId, teammateA]:
        addParticipant(sessionId, player)
      addGame(sessionId, 0, 0, sourceId, targetId)

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      check outcome.error == meSessionCollision

      check countRows(db, communityId, "player.merge_log") == "0"
      check countRows(db, communityId, "player.aliases") == aliasBefore
      check db.queryOne(
        "select id from player.players where id = $1::uuid",
        @[textParam(sourceId)]).isSome
      for player in [sourceId, targetId]:
        check db.queryOne(
          """select count(*)::int as total from session.participants
             where community_id = $1::uuid and player_id = $2::uuid""",
          @[textParam(communityId), textParam(player)]).get.get("total") == "1"
      let game = db.queryOne(
        """select side_a1, side_b1 from session.games
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get
      check game.get("side_a1") == sourceId
      check game.get("side_b1") == targetId
      check db.queryOne(
        """select count(*)::int as total from player.aliases
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)]).get.get("total") == "1"

  test "a duplicate skip of both players collapses to one row":
    block:
      unblockMerge()
      let teammateA = playerId("Merge Partner A")
      let teammateB = playerId("Merge Partner B")
      let sessionId = addSession("Duplicate skip")
      for player in [sourceId, targetId, teammateA, teammateB]:
        addParticipant(sessionId, player)
      # Neither merged player sits in the first game, so both were skipped there.
      addGame(sessionId, 0, 0, teammateA, teammateB)
      addGame(sessionId, 0, 1, sourceId, teammateA)
      addGame(sessionId, 0, 2, targetId, teammateB)
      for player in [sourceId, targetId]:
        discard db.execUpdate(
          """insert into session.game_skips
               (community_id, session_id, round_no, court_no, player_id)
             values ($1::uuid, $2::uuid, 0, 0, $3::uuid)""",
          @[textParam(communityId), textParam(sessionId), textParam(player)])

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      check outcome.error == meOk
      check outcome.result.skipsMoved == 0
      check db.queryOne(
        """select count(*)::int as total from session.game_skips
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get.get("total") == "1"
      check db.queryOne(
        """select player_id from session.game_skips
           where community_id = $1::uuid and session_id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get.get("player_id") ==
        targetId

  test "a pair with the same partner on both sides refuses the merge":
    block:
      unblockMerge()
      let teammateId = playerId("Merge Partner A")
      for owner in [sourceId, targetId]:
        discard db.execUpdate(
          """insert into tournament.pairs
               (community_id, tournament_id, display_name, player_a_id, player_b_id)
             select $1::uuid, id, 'Merge Pair', $2::uuid, $3::uuid
             from tournament.tournaments where community_id = $1::uuid""",
          @[textParam(communityId), textParam(owner), textParam(teammateId)])

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      # Both pairs would become (target, teammate), so the tournament would
      # count the same team twice.
      check outcome.error == mePairCollision
      check countRows(db, communityId, "player.merge_log") == "0"
      check countRows(db, communityId, "player.aliases") == aliasBefore
      check countRows(db, communityId, "tournament.pairs") == "3"
      for player in [targetId, sourceId]:
        check db.queryOne(
          "select id from player.players where id = $1::uuid",
          @[textParam(player)]).isSome

  test "pairs with a different partner on each side merge":
    block:
      unblockMerge()
      let teammateA = playerId("Merge Partner A")
      let teammateB = playerId("Merge Partner B")
      for entry in [(sourceId, teammateA), (targetId, teammateB)]:
        discard db.execUpdate(
          """insert into tournament.pairs
               (community_id, tournament_id, display_name, player_a_id, player_b_id)
             select $1::uuid, id, 'Merge Pair', $2::uuid, $3::uuid
             from tournament.tournaments where community_id = $1::uuid""",
          @[textParam(communityId), textParam(entry[0]), textParam(entry[1])])

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      check outcome.error == meOk
      check outcome.result.pairsMoved == 1
      # The moved pair now names the target, next to the target's own pair.
      check db.queryOne(
        """select count(*)::int as total from tournament.pairs
           where community_id = $1::uuid
             and (player_a_id = $2::uuid or player_b_id = $2::uuid)""",
        @[textParam(communityId), textParam(targetId)]).get.get("total") == "2"

  test "a moved roster spot takes the target's name":
    block:
      unblockMerge()
      let teamId = db.queryOne(
        """insert into tournament.teams
             (community_id, tournament_id, seed, team_name)
           select $1::uuid, id, 1, 'Merge Team'
           from tournament.tournaments where community_id = $1::uuid
           returning id""",
        @[textParam(communityId)]).get.get("id")
      discard db.execUpdate(
        """insert into tournament.team_players
             (community_id, team_id, player_id, player_name, cls)
           values ($1::uuid, $2::uuid, $3::uuid, 'Merge Source', 'A')""",
        @[textParam(communityId), textParam(teamId), textParam(sourceId)])

      let outcome = merge(db, communityId, targetId, sourceId, actorId)
      check outcome.error == meOk
      check outcome.result.teamPlayersMoved == 1
      # The roster renders the stored name, which must follow the new owner.
      check db.queryOne(
        """select player_name from tournament.team_players
           where community_id = $1::uuid and team_id = $2::uuid""",
        @[textParam(communityId), textParam(teamId)]).get.get("player_name") ==
        "Merge Target"
