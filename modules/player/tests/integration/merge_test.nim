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