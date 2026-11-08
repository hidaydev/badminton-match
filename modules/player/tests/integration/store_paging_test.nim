## Player store edges BE-16 names: keyset paging, the tier filter, remove with
## the alias cascade, and `ownedBy`. The page-size cap belongs to the HTTP
## route, so it is asserted there, not here. Needs MAJADU_PG_DSN.

import std/[json, options, os, unittest]
import db/db
import tests/fixtures
import ../../store

const slug = "be16-player-store"

if getEnv("MAJADU_PG_DSN").len == 0:
  raise newException(ValueError, "MAJADU_PG_DSN is required")

suite "player store contract":
  var db: Db
  var communityId: string

  proc reset() =
    purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'be16-%'")
    communityId = newCommunity(db, slug, "BE16 Player Store")

  setup:
    db = openDb(getEnv("MAJADU_PG_DSN"), 1)
    reset()

  teardown:
    purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub like 'be16-%'")
    db.close()

  test "list pages by id cursor without repeating a row and filters on tier":
    var ids: seq[string] = @[]
    for name in ["Paging A", "Paging B", "Paging C", "Paging D"]:
      ids.add(newPlayer(db, communityId, name))
    discard db.execUpdate(
      "update player.players set tier = 'B+' where id = $1::uuid",
      @[textParam(ids[0])])
    discard db.execUpdate(
      "update player.players set tier = 'B' where id = $1::uuid",
      @[textParam(ids[1])])

    let page1 = list(db, communityId, 2)
    check page1.len == 2
    let page2 = list(db, communityId, 2, cursor = page1[1]["id"].getStr())
    check page2.len == 2
    var seen: seq[string] = @[]
    for row in page1:
      seen.add(row["id"].getStr())
    for row in page2:
      let id = row["id"].getStr()
      # A cursor from the last row of page one must not repeat it or anything
      # before it.
      check id notin seen
      seen.add(id)
    # Both pages together cover the four players exactly once.
    for id in ids:
      check id in seen
    check list(db, communityId, 2, cursor = page2[1]["id"].getStr()).len == 0

    let plus = list(db, communityId, 10, tier = "B+")
    check plus.len == 1
    check plus[0]["id"].getStr() == ids[0]
    let plainB = list(db, communityId, 10, tier = "B")
    check plainB.len == 1
    check plainB[0]["id"].getStr() == ids[1]

  test "remove returns true once and takes the aliases with the row":
    let playerId = newPlayer(db, communityId, "Removable Player")
    check setAliases(db, communityId, playerId,
      @["Removable Alias", "Second Alias"])
    check aliases(db, communityId, playerId).len == 2

    check remove(db, communityId, playerId)
    check not remove(db, communityId, playerId)
    check get(db, communityId, playerId).isNone
    check db.queryOne(
      """select count(*)::int as n from player.aliases
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(playerId)]).get.get("n") == "0"

  test "ownedBy answers the bound account and none for another":
    let owner = newUser(db, "be16-owned-owner", "be16-owned-owner@example.com")
    let other = newUser(db, "be16-owned-other", "be16-owned-other@example.com")
    let playerId = newPlayer(db, communityId, "Bound Player", userId = owner)

    let owned = ownedBy(db, communityId, owner)
    check owned.isSome
    check owned.get["id"].getStr() == playerId
    check owned.get["userId"].getStr() == owner
    check ownedBy(db, communityId, other).isNone