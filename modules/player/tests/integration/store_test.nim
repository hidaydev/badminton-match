import std/[json, options, os, unittest]
import db/db
import ../../store
import ../../domain/player

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc addPlayer(db: Db, communityId, name: string): string =
  db.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

suite "player store":
  var db: Db
  var communityId, targetId, otherId: string

  proc cleanup() =
    for statement in [
      """delete from player.aliases where community_id in
           (select id from platform.community where slug = 'player-store-test')""",
      """delete from player.players where community_id in
           (select id from platform.community where slug = 'player-store-test')""",
      "delete from platform.community where slug = 'player-store-test'"]:
      discard db.execUpdate(statement)

  setup:
    db = openDb(dsn(), 1)
    cleanup()
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('player-store-test', 'Player Store Test', 'Asia/Jakarta')
         returning id""").get.get("id")
    targetId = addPlayer(db, communityId, "Patch Target")
    otherId = addPlayer(db, communityId, "Other Player")
    check setAliases(db, communityId, targetId, @["Target Alias"])
    check setAliases(db, communityId, otherId, @["Taken Alias"])

  teardown:
    cleanup()
    db.close()

  test "a patch naming a taken alias writes nothing at all":
    let outcome = patch(db, communityId, targetId,
      PlayerPatch(name: some("Renamed Target"),
        aliases: some(@["Taken Alias", "Fresh Alias"])))

    check outcome.aliasTaken
    check db.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(targetId)]).get.get("canonical_name") == "Patch Target"
    check aliases(db, communityId, targetId) == @["Target Alias"]
    # The other player keeps the alias that caused the conflict.
    check aliases(db, communityId, otherId) == @["Taken Alias"]

  test "a patch replaces the row and its aliases together":
    let outcome = patch(db, communityId, targetId,
      PlayerPatch(name: some("Renamed Target"),
        aliases: some(@["Fresh Alias"])))

    check outcome.status == psOk
    check not outcome.aliasTaken
    check outcome.player["name"].getStr() == "Renamed Target"
    check db.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(targetId)]).get.get("canonical_name") == "Renamed Target"
    check aliases(db, communityId, targetId) == @["Fresh Alias"]

  test "the route's patch then setAliases sequence writes nothing on a conflict":
    ## `patchPlayerRoute` still calls `setAliases` after `patch`; both writes sit
    ## in the same failure domain, so the second call must not surprise it.
    let patchBody = PlayerPatch(name: some("Renamed Target"),
      aliases: some(@["Taken Alias"]))
    let outcome = patch(db, communityId, targetId, patchBody)
    check outcome.status == psOk
    check not setAliases(db, communityId, targetId, patchBody.aliases.get)

    check db.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(targetId)]).get.get("canonical_name") == "Patch Target"
    check aliases(db, communityId, targetId) == @["Target Alias"]

  test "a duplicate name reports duplicate without touching the aliases":
    let outcome = patch(db, communityId, targetId,
      PlayerPatch(name: some("Other Player")))

    check outcome.status == psDuplicate
    check aliases(db, communityId, targetId) == @["Target Alias"]

  test "a search treats LIKE wildcards literally":
    discard addPlayer(db, communityId, "Percent 100%")
    check list(db, communityId, 10, search = "100%").len == 1
    # "%" and "_" would match every player if they stayed wildcards.
    check list(db, communityId, 10, search = "%").len == 1
    check list(db, communityId, 10, search = "_").len == 0

  test "a search matches an alias, not just the canonical name":
    # "Target Alias" is only an alias of "Patch Target".
    let byAlias = list(db, communityId, 10, search = "target alias")
    check byAlias.len == 1
    check byAlias[0]["id"].getStr() == targetId
    # Alias matching is literal too, and stays inside the community.
    check list(db, communityId, 10, search = "%").len == 0
    check list(db, communityId, 10, search = "taken_").len == 0
