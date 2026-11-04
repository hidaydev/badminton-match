import std/unittest
import ../src/routes_gen

suite "generated contract":
  test "contains every operation":
    check routeCount == 74
    check routes.len == 74
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
      "postRatingsRebuild", "createCommunity", "listMyCommunities", "createJoinRequest",
      "listJoinRequests", "decideJoinRequest", "createInvite", "acceptInvite",
      "listMembers", "patchMemberRole", "removeMember", "getSettings", "patchSettings",
      "getCommunityConfig", "getDirectory"
    ])
