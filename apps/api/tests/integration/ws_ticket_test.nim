import std/[options, os, unittest]
import db/db
import sha256
import uuidv7
import tests/fixtures
import ../../src/live
import ../../src/ws_ticket

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "ws tickets":
  var db: Db
  var hub: LiveHub
  var communityId, otherCommunityId, sessionId, otherSessionId: string
  var userId, otherUserId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    hub = newHub(db)
    for slug in ["ws-ticket-test", "ws-ticket-other"]:
      purgeCommunity(db, slug)
    discard db.execUpdate(
      "delete from platform.user where google_sub in ('ws-ticket-user','ws-ticket-other')")
    userId = newUser(db, "ws-ticket-user", "ws-hash", "Watcher")
    otherUserId = newUser(db, "ws-ticket-other", "ws-hash-2", "Other")
    communityId = newCommunity(db, "ws-ticket-test", "Ticket Test")
    otherCommunityId = newCommunity(db, "ws-ticket-other", "Ticket Other")
    sessionId = newSession(db, communityId, "Session", "2026-11-03")
    otherSessionId = newSession(db, otherCommunityId, "Other", "2026-11-03")

  teardown:
    db.close()

  test "the plaintext ticket is never stored":
    let token = issueSession(db, userId, sessionId, 60)
    check token.len == 64
    let row = db.queryOne(
      """select encode(token_hash,'hex') as token_hash, channel_kind,
                channel_id, user_id
         from platform.ws_ticket where token_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(token))])
    check row.isSome
    check row.get.get("token_hash") == sha256Hex(token)
    check row.get.get("token_hash") != token
    check row.get.get("channel_kind") == kindSession
    check row.get.get("channel_id") == sessionId
    check row.get.get("user_id") == userId

  test "consume returns the channel once and a replay is a miss":
    let token = issueSession(db, userId, sessionId, 60)
    let first = consume(db, token, kindSession, sessionId)
    check first.isSome
    check first.get.channelId == sessionId
    check first.get.userId == some(userId)
    check consume(db, token, kindSession, sessionId).isNone

  test "a ticket for another channel is rejected and burned":
    let token = issueSession(db, userId, sessionId, 60)
    check consume(db, token, kindSession, otherSessionId).isNone
    check consume(db, token, kindSession, sessionId).isNone

  test "a share ticket cannot be used on a session channel":
    let token = issueShare(db, sessionId, 60)
    check consume(db, token, kindSession, sessionId).isNone
    let row = db.queryOne(
      "select count(*) as n from platform.ws_ticket where token_hash = decode($1,'hex')",
      @[textParam(sha256Hex(token))])
    check row.get.get("n") == "0"

  test "an expired ticket is a miss and can never be consumed":
    let token = issueSession(db, userId, sessionId, 60)
    discard db.execUpdate(
      """update platform.ws_ticket
         set expires_at = now() - interval '1 second'
         where token_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(token))])
    check consume(db, token, kindSession, sessionId).isNone
    # Expiry is evaluated in the DELETE, so the row survives for the janitor and
    # stays unusable: a second attempt is still a miss.
    check consume(db, token, kindSession, sessionId).isNone

  test "an anonymous share ticket has no principal":
    let token = issueShare(db, sessionId, 60)
    let consumed = consume(db, token, kindShare, sessionId)
    check consumed.isSome
    check consumed.get.userId.isNone

  test "revocation deletes every ticket of the principal":
    let first = issueSession(db, userId, sessionId, 60)
    let second = issueSession(db, userId, otherSessionId, 60)
    let untouched = issueSession(db, otherUserId, sessionId, 60)
    check revokePrincipal(db, userId) == 2
    check consume(db, first, kindSession, sessionId).isNone
    check consume(db, second, kindSession, otherSessionId).isNone
    check consume(db, untouched, kindSession, sessionId).isSome

  test "revocation by share link deletes only that link":
    let keptLink = uuidv7()
    let revokedLink = uuidv7()
    let first = issueShare(db, revokedLink, 60)
    let second = issueShare(db, revokedLink, 60)
    let kept = issueShare(db, keptLink, 60)
    check revokeShare(db, revokedLink) == 2
    check consume(db, first, kindShare, revokedLink).isNone
    check consume(db, second, kindShare, revokedLink).isNone
    check consume(db, kept, kindShare, keptLink).isSome

  test "the hub helper deletes the tickets it is asked to revoke":
    let token = issueSession(db, userId, sessionId, 60)
    hub.revokePrincipal(userId)
    check consume(db, token, kindSession, sessionId).isNone

  test "the hub share helper deletes tickets of that link":
    let linkId = uuidv7()
    let token = issueShare(db, linkId, 60)
    hub.revokeShare(linkId)
    check consume(db, token, kindShare, linkId).isNone
