import std/unittest
import ../src/routes_gen

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
