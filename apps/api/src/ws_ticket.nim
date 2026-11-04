import std/[options, strutils, sysrand]
import db/db
import sha256

type
  ConsumedTicket* = object
    ## A ticket that was present, unexpired and matched the requested channel.
    channelKind*: string
    channelId*: string
    userId*: Option[string]

const
  kindSession* = "session"
  kindShare* = "share"

proc randomTicket*(): string =
  ## 32 random bytes, hex encoded. Only the hash is stored (D14).
  var bytes: array[32, byte]
  if not urandom(bytes):
    raise newException(IOError, "cannot read random bytes")
  for value in bytes:
    result.add(toHex(value, 2).toLowerAscii)

proc store(db: Db, token, kind, channelId: string, userId: Option[string],
           ttlSeconds: int) =
  discard db.execUpdate(
    """insert into platform.ws_ticket
         (token_hash, channel_kind, channel_id, user_id, expires_at)
       values (decode($1,'hex'), $2, $3::uuid, $4::uuid,
               now() + make_interval(secs => $5))""",
    @[textParam(sha256Hex(token)), textParam(kind), textParam(channelId),
      (if userId.isSome: textParam(userId.get) else: nullParam()),
      intParam(ttlSeconds.int64)])

proc issueSession*(db: Db, userId, sessionId: string, ttlSeconds: int): string =
  ## Session tickets always carry a principal; `ws_ticket_share_anonymous`
  ## rejects a NULL user_id on a session channel.
  result = randomTicket()
  store(db, result, kindSession, sessionId, some(userId), ttlSeconds)

proc issueShare*(db: Db, linkId: string, ttlSeconds: int): string =
  ## Anonymous watchers: the ticket names the link row, never the raw code.
  result = randomTicket()
  store(db, result, kindShare, linkId, none(string), ttlSeconds)

proc consume*(db: Db, token, kind, channelId: string): Option[ConsumedTicket] =
  ## One DELETE ... RETURNING is the whole check: expiry is evaluated by the
  ## database and two racing upgrades cannot both win. A ticket that was valid
  ## but named another channel is burned and reported as a miss, so a mismatched
  ## URL never leaves the ticket reusable.
  if token.len == 0:
    return none(ConsumedTicket)
  let row = db.queryOne(
    """delete from platform.ws_ticket
       where token_hash = decode($1,'hex') and expires_at > now()
       returning channel_kind, channel_id, user_id""",
    @[textParam(sha256Hex(token))])
  if row.isNone:
    return none(ConsumedTicket)
  let value = row.get
  if value.get("channel_kind") != kind or value.get("channel_id") != channelId:
    return none(ConsumedTicket)
  some(ConsumedTicket(
    channelKind: value.get("channel_kind"),
    channelId: value.get("channel_id"),
    userId: if value["user_id"].isNone: none(string) else: some(value.get("user_id")),
  ))

proc revokePrincipal*(db: Db, userId: string): int =
  ## Every ticket of the principal, not only the channel being changed: a ticket
  ## issued before a logout must not open a socket afterwards.
  db.execUpdate(
    "delete from platform.ws_ticket where user_id = $1::uuid",
    @[textParam(userId)])

proc revokeShare*(db: Db, linkId: string): int =
  db.execUpdate(
    """delete from platform.ws_ticket
       where channel_kind = 'share' and channel_id = $1::uuid""",
    @[textParam(linkId)])
