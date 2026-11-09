## BE-17: every collection route takes a page window and answers the same
## envelope. These are the six that used to return the whole community.

import std/[json, unittest]
import db/db
import tests/fixtures
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "collection-page"
  adminEmail = "collection-page-admin@example.com"

var
  database: Db
  communityId, adminId: string
  adminCookie, memberCookie: string
  players: seq[string]

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like 'collection-page-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'collection-page-%'")

  adminId = newUser(database, "collection-page-admin", adminEmail, "Page Admin")
  communityId = newCommunity(database, slug, "Page Club")
  newMember(database, communityId, adminId, "admin")
  adminCookie = cookieFor(database, adminId)
  let memberId = newUser(database, "collection-page-member",
    "collection-page-member@example.com", "Page Member")
  newMember(database, communityId, memberId, "member")
  memberCookie = cookieFor(database, memberId)

  # Five members total, so limit 2 needs three pages.
  for index in 0 ..< 4:
    let id = newUser(database, "collection-page-extra" & $index,
      "collection-page-extra" & $index & "@example.com", "Extra " & $index)
    newMember(database, communityId, id, "member")

  # Three pending join requests.
  for index in 0 ..< 3:
    let id = newUser(database, "collection-page-asker" & $index,
      "collection-page-asker" & $index & "@example.com", "Asker " & $index)
    discard newJoinRequest(database, communityId, id)

  # Four players; three of them carry a pending claim for the admin queue.
  for name in ["Ani", "Budi", "Cakra", "Dewi"]:
    players.add(newPlayer(database, communityId, name))
  for player in players[0 .. 2]:
    discard newClaim(database, communityId, player, memberId)
  # A fourth pending claim would break the one-pending index, so the claim
  # trail of the first player gets three decided rows instead.
  for index in 0 ..< 3:
    discard database.execUpdate(
      """insert into player.claims
           (community_id, player_id, user_id, status, decided_by, decided_at,
            reason, created_at)
         values ($1::uuid, $2::uuid, $3::uuid, 'released', $3::uuid, now(),
                 'released by member', now() - make_interval(days => $4))""",
      @[textParam(communityId), textParam(players[0]),
        textParam(memberId), intParam(index.int64)])

  # Three earned badges for the first player.
  for key in ["sessions:10", "wins:5", "games:10"]:
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at)
         values ($1::uuid, $2::uuid, $3, now())""",
      @[textParam(communityId), textParam(players[0]), textParam(key)])

  # Three rating events plus two tournaments that were never ingested: five
  # sources across the two halves of the union.
  for index in 0 ..< 3:
    discard database.execUpdate(
      """insert into rating.events
           (community_id, local_date, event_type, point_entries)
         values ($1::uuid, $2::date, 'manual', $3)""",
      @[textParam(communityId),
        textParam("2026-10-0" & $(index + 1)),
        intParam(index.int64 + 1)])
  for index in 0 ..< 2:
    discard database.execUpdate(
      """insert into tournament.tournaments
           (community_id, name, status, format, event_date)
         values ($1::uuid, $2, 'completed', 'classic', $3::date)""",
      @[textParam(communityId), textParam("Unrated cup " & $index),
        textParam("2026-09-0" & $(index + 1))])

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

proc page(path, cookie: string): JsonNode =
  let response = call(baseUrl, HttpGet, path, cookie)
  checkpoint(path & " -> " & $response.status & " " & response.body)
  expectStatus(response, 200)
  response.json()

suite "collection paging":
  test "listMembers pages the roster and reports the whole count":
    let first = page("/c/" & slug & "/members?limit=2", memberCookie)
    check first["items"].len == 2
    check first["total"].getInt() == 6
    check first["nextCursor"].getStr() == "2"

    let last = page("/c/" & slug & "/members?limit=2&offset=4", memberCookie)
    check last["items"].len == 2
    check last["total"].getInt() == 6
    check last["nextCursor"].getStr().len == 0

  test "listJoinRequests pages the pending queue":
    let body = page("/c/" & slug & "/join-requests?limit=1", adminCookie)
    check body["items"].len == 1
    check body["total"].getInt() == 3
    check body["nextCursor"].getStr() == "1"

  test "listPendingClaims pages the admin claim queue":
    let body = page("/c/" & slug & "/claims?limit=2", adminCookie)
    check body["items"].len == 2
    check body["total"].getInt() == 3
    check body["nextCursor"].getStr() == "2"

  test "listPlayerClaims pages one player's trail":
    let body = page("/c/" & slug & "/players/" & players[0] &
      "/claims?limit=2", adminCookie)
    check body["items"].len == 2
    check body["total"].getInt() == 4
    check body["nextCursor"].getStr() == "2"

  test "getPlayerAchievements pages the badges":
    let body = page("/c/" & slug & "/players/" & players[0] &
      "/achievements?limit=2", memberCookie)
    check body["items"].len == 2
    check body["total"].getInt() == 3
    check body["nextCursor"].getStr() == "2"

  test "listRatingSources pages across events and unrated tournaments":
    let first = page("/c/" & slug & "/rating-sources?limit=2", adminCookie)
    check first["items"].len == 2
    check first["total"].getInt() == 5
    check first["nextCursor"].getStr() == "2"

    let second = page("/c/" & slug & "/rating-sources?limit=2&offset=2",
      adminCookie)
    check second["items"].len == 2
    check second["nextCursor"].getStr() == "4"

    let last = page("/c/" & slug & "/rating-sources?limit=2&offset=4",
      adminCookie)
    check last["items"].len == 1
    check last["nextCursor"].getStr().len == 0

  test "the platform ceiling clamps a request larger than the page":
    let body = page("/c/" & slug & "/members?limit=99999", memberCookie)
    check body["items"].len == 6
    check body["nextCursor"].getStr().len == 0
