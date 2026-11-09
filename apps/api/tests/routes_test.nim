import std/[json, os, strutils, unittest]
import ../src/routes_gen

const collectionOperations = [
  "listSessions", "listMembers", "listJoinRequests", "listPendingClaims",
  "listPlayerClaims", "listRatingSources", "getPlayerAchievements"]
  ## Every operation that returns one page of a collection. The UI calls these
  ## on page load, so an unbounded body is a latency and memory problem, not
  ## only a contract one.

const mergedSpec = currentSourcePath().parentDir /
  "../../../packages/contracts/openapi/api.yaml"

suite "generated contract":
  test "contains every operation":
    check routeCount == 76
    check routes.len == 76
    check routeIndex("getHealthz") >= 0
    check routeIndex("getCommunityConfig") >= 0
    check routeIndex("nope") == -1

  test "compile-time handler check accepts the full list":
    verifyHandlers([
      "getHealthz", "getReadyz", "getVersion", "postAuthStart", "getAuthCallback",
      "postAuthLogout", "getAuthMe", "listAuthSessions", "deleteAuthSessions",
      "listSessions", "createSession", "getSession", "patchSession", "deleteSession",
      "lockSession", "unlockSession", "putSessionSchedule", "getSessionGame",
      "getSessionStandings",
      "patchSessionGame", "skipSessionGame", "patchSessionAbsent", "postSessionSwap",
      "createShareLink", "deleteShareLink", "getShareLink", "getSharedSession",
      "wsSession", "wsShare", "postSessionWsTicket", "postShareWsTicket",
      "listPlayers", "createPlayer", "getPlayer", "patchPlayer", "deletePlayer",
      "getPlayerStats", "getPlayerAchievements", "postPlayerMerge", "postPlayerClaim",
      "listPlayerClaims", "patchPlayerClaim", "deleteOwnClaim", "listTournaments",
      "createTournament", "getTournament", "putTournament", "deleteTournament",
      "patchTournamentMatch", "listRankings", "getRanking", "listSharedRankings",
      "getSharedRanking", "listRatingSources", "postSessionRating", "deleteSessionRating",
      "postTournamentRating", "deleteTournamentRating", "patchRatingSource",
      "deleteRatingSource",
      "postRatingsRebuild", "createCommunity", "listMyCommunities", "createJoinRequest",
      "listJoinRequests", "decideJoinRequest", "createInvite", "acceptInvite",
      "listMembers", "listPendingClaims", "patchMemberRole", "removeMember",
      "getSettings", "patchSettings",
      "getCommunityConfig", "getDirectory"
    ])

  test "every collection operation takes limit and offset":
    for operationId in collectionOperations:
      let index = routeIndex(operationId)
      checkpoint(operationId)
      check index >= 0
      if index < 0:
        continue
      let params = routes[index].queryParams.split(',')
      check "limit" in params
      check "offset" in params

  test "every collection response declares items, total and nextCursor":
    let document = parseFile(mergedSpec)
    for operationId in collectionOperations:
      checkpoint(operationId)
      var schemaName = ""
      for path in document["paths"].keys:
        let node = document["paths"][path]
        if node.kind != JObject:
          continue
        for verb in ["get", "post", "put", "patch", "delete"]:
          if not node.hasKey(verb):
            continue
          if node[verb].kind != JObject:
            continue
          if node[verb]["operationId"].getStr() != operationId:
            continue
          if not node[verb].hasKey("responses"):
            continue
          if not node[verb]["responses"].hasKey("200"):
            continue
          if not node[verb]["responses"]["200"].hasKey("content"):
            continue
          let body = node[verb]["responses"]["200"]["content"]["application/json"]["schema"]
          if body.hasKey("$ref"):
            schemaName = body["$ref"].getStr().split('/')[^1]
      check schemaName.len > 0
      if schemaName.len == 0:
        continue
      let schema = document["components"]["schemas"][schemaName]
      let required = schema["required"]
      check required.contains(%"items")
      check required.contains(%"total")
      check required.contains(%"nextCursor")
