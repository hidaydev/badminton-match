import std/options
import db/db
import sha256
import token

type
  SessionUser* = object
    userId*: string
    displayName*: string
    emailHash*: string
    isPlatformOwner*: bool

  SessionRow* = object
    id*: string
    createdAt*: string
    lastSeenAt*: string
    current*: bool

proc createSession*(db: Db, userId: string, absoluteDays: int): string =
  ## Returns the raw cookie value. Only its SHA-256 is stored, so a database
  ## dump cannot be replayed as a session.
  result = newOpaqueToken()
  discard db.execUpdate(
    """insert into account.sessions
         (user_id, token_hash, absolute_expires_at)
       values ($1::uuid, decode($2,'hex'), now() + make_interval(days => $3))""",
    @[textParam(userId), textParam(sha256Hex(result)), intParam(absoluteDays.int64)])

proc resolve*(db: Db, token: string, idleDays: int): Option[SessionUser] =
  ## One statement both checks the session and refreshes `last_seen_at`:
  ## revoked, idle-expired or absolutely expired rows never match.
  if token.len == 0:
    return none(SessionUser)
  let row = db.queryOne(
    """with touched as (
         update account.sessions s
         set last_seen_at = now()
         where s.token_hash = decode($1,'hex')
           and s.revoked_at is null
           and s.absolute_expires_at > now()
           and s.last_seen_at > now() - make_interval(days => $2)
         returning s.user_id)
       select u.id, u.display_name, u.email_hash, u.is_platform_owner
       from touched t join platform.user u on u.id = t.user_id""",
    @[textParam(sha256Hex(token)), intParam(idleDays.int64)])
  if row.isNone:
    return none(SessionUser)
  let value = row.get
  some(SessionUser(
    userId: value.getUuid("id"),
    displayName: value.get("display_name"),
    emailHash: value.get("email_hash"),
    isPlatformOwner: value.getBool("is_platform_owner"),
  ))

proc revoke*(db: Db, token: string) =
  ## The next request with this cookie fails, because `resolve` requires
  ## `revoked_at is null`. Websocket tickets for the principal go with it.
  let row = db.queryOne(
    """update account.sessions set revoked_at = now()
       where token_hash = decode($1,'hex') and revoked_at is null
       returning user_id""",
    @[textParam(sha256Hex(token))])
  if row.isNone:
    return
  discard db.execUpdate(
    "delete from platform.ws_ticket where user_id = $1::uuid",
    @[textParam(row.get.getUuid("user_id"))])

proc revokeOthers*(db: Db, userId, keepToken: string) =
  discard db.execUpdate(
    """update account.sessions set revoked_at = now()
       where user_id = $1::uuid and revoked_at is null
         and token_hash <> decode($2,'hex')""",
    @[textParam(userId), textParam(sha256Hex(keepToken))])
  discard db.execUpdate(
    "delete from platform.ws_ticket where user_id = $1::uuid",
    @[textParam(userId)])

proc listSessions*(db: Db, userId, currentToken: string): seq[SessionRow] =
  for row in db.query(
    """select id, created_at::text as created_at, last_seen_at::text as last_seen_at,
              (token_hash = decode($2,'hex')) as is_current
       from account.sessions
       where user_id = $1::uuid and revoked_at is null
         and absolute_expires_at > now()
       order by last_seen_at desc""",
    @[textParam(userId), textParam(sha256Hex(currentToken))]):
    result.add(SessionRow(
      id: row.getUuid("id"),
      createdAt: row.get("created_at"),
      lastSeenAt: row.get("last_seen_at"),
      current: row.getBool("is_current"),
    ))
