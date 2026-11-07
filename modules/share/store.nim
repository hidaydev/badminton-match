import std/[options]
import db/db
import crypto
import hex
import uuidv7
import sha256

type
  ShareLookup* = object
    linkId*: string
    communityId*: string
    sessionId*: string
    slug*: string
    communityName*: string
    timezone*: string
    title*: string
    sessionDate*: string
    status*: string

## One definition of "live": a link resolves, is re-displayable, and is watched
## only while this holds. The partial unique index in `0001_core.sql` is looser,
## it only excludes revoked rows, so an expired row must still be revoked to
## free the index.
const liveLinkSql = "revoked_at is null and (expires_at is null or expires_at > now())"

proc aadFor(communityId, linkId: string): string =
  ## Binds a ciphertext to the exact row and community it was minted for.
  communityId & "|" & linkId

proc revokeLiveConn(conn: DbConn, communityId, sessionId: string): seq[string] =
  ## Revokes the session's unrevoked rows and returns their ids. Expired rows are
  ## revoked too, so the partial unique index never holds a dead row.
  for row in conn.query(
    """update session.links set revoked_at = now()
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null
       returning id""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("id"))

proc issue*(db: Db, keyring: Keyring, communityId, sessionId,
            createdBy: string, ttlDays: int): string =
  ## Rotating the *link*: the previous live code stops resolving in the same
  ## transaction because a partial unique index allows only one live row. Links
  ## expire: a code forwarded in a group chat should not resolve forever.
  ## The new row leaves `legacy_id_ok` at its default (false), so the session id
  ## cannot stand in for it; only pre-code rows carry that shortcut.
  let linkId = uuidv7()
  let code = newShareCode()
  let (keyId, encrypted) = encryptWith(keyring, code, aadFor(communityId, linkId))
  db.tx(proc(conn: DbConn) =
    discard revokeLiveConn(conn, communityId, sessionId)
    discard conn.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_by,
            expires_at)
         values ($1::uuid, $2::uuid, $3::uuid, decode($4,'hex'), decode($5,'hex'),
                 $6, $7::uuid, now() + make_interval(days => $8))""",
      @[textParam(linkId), textParam(communityId), textParam(sessionId),
        textParam(sha256Hex(code)), textParam(bytesHex(encrypted)),
        textParam(keyId), textParam(createdBy), intParam(ttlDays.int64)]))
  code

proc currentCode*(db: Db, keyring: Keyring, communityId,
                  sessionId: string): Option[string] =
  ## Re-display for a host or admin. The caller audits the read; the code itself
  ## never leaves this row in any other response.
  let row = db.queryOne(
    """select id, key_id, encode(code_enc,'hex') as code_enc
       from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and """ & liveLinkSql,
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return none(string)
  let value = row.get
  try:
    some(decryptWith(keyring, value.get("key_id"),
      hexBytes(value.get("code_enc")), aadFor(communityId, value.get("id"))))
  except ShareKeyError:
    none(string)

const shareLookupFrom = """
       from session.links l
       join session.sessions s
         on s.community_id = l.community_id and s.id = l.session_id
       join platform.community c on c.id = l.community_id
       where """

const shareLookupColumns = """select l.id as link_id, l.community_id, l.key_id,
              l.session_id, encode(l.code_enc,'hex') as code_enc,
              s.title, s.session_date::text as session_date, s.status,
              c.slug, c.name, c.timezone
       """

proc looksLikeUuid(value: string): bool =
  ## Version one shared a session by its id. Only that exact shape is treated as
  ## an id, so a mistyped code never reaches a `::uuid` cast.
  if value.len != 36:
    return false
  for index, character in value:
    if index in [8, 13, 18, 23]:
      if character != '-':
        return false
    elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc resolve*(db: Db, keyring: Keyring, code: string): Option[ShareLookup] =
  var row = db.queryOne(
    shareLookupColumns & shareLookupFrom &
    """l.code_hash = decode($1,'hex') and """ & liveLinkSql,
    @[textParam(sha256Hex(code))])
  if row.isNone and looksLikeUuid(code):
    # A link minted before the code era was `/s/{sessionId}`. Only those rows
    # answer for an id, so links already in a group chat keep working while a
    # rotated link revokes that shape together with the old code.
    row = db.queryOne(
      shareLookupColumns & shareLookupFrom &
      """l.session_id = $1::uuid and l.legacy_id_ok and """ & liveLinkSql,
      @[textParam(code)])
  if row.isNone:
    return none(ShareLookup)
  let value = row.get
  # The envelope must prove it belongs to this row before the row is served.
  try:
    discard decryptWith(keyring, value.get("key_id"),
      hexBytes(value.get("code_enc")),
      aadFor(value.get("community_id"), value.get("link_id")))
  except ShareKeyError:
    return none(ShareLookup)
  some(ShareLookup(
    linkId: value.get("link_id"),
    communityId: value.get("community_id"),
    sessionId: value.get("session_id"),
    slug: value.get("slug"),
    communityName: value.get("name"),
    timezone: value.get("timezone"),
    title: value.get("title"),
    sessionDate: value.get("session_date"),
    status: value.get("status"),
  ))

proc liveLinks*(db: Db, communityId, sessionId: string): seq[string] =
  ## Ids of the links a delete is about to take with it, so their watchers can be
  ## closed without revoking anything first. Expired rows are not live, so they
  ## are not listed: `resolve` would refuse them anyway.
  for row in db.query(
    """select id from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and """ & liveLinkSql,
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("id"))

proc revokeLive*(db: Db, communityId, sessionId: string): seq[string] =
  ## Revokes every unrevoked link for the session and returns their ids so the
  ## caller can drop the watchers and their tickets. An empty result means
  ## there was nothing to revoke.
  result = db.txRet(proc(conn: DbConn): seq[string] =
    revokeLiveConn(conn, communityId, sessionId))

proc rotateKeys*(db: Db, keyring: Keyring, fromKeyId, toKeyId: string): int =
  ## Rotating the *key*: every live link still sealed with `fromKeyId` is
  ## re-encrypted under the active key with a fresh nonce. Rows already on the
  ## target key are skipped, so running it twice changes nothing the second time.
  if fromKeyId == toKeyId:
    return 0
  let rows = db.query(
    """select id, community_id, key_id, encode(code_enc,'hex') as code_enc
       from session.links
       where key_id = $1""",
    @[textParam(fromKeyId)])
  for row in rows:
    let linkId = row.get("id")
    let communityId = row.get("community_id")
    var code = ""
    try:
      code = decryptWith(keyring, fromKeyId, hexBytes(row.get("code_enc")),
        aadFor(communityId, linkId))
    except ShareKeyError:
      continue
    let (newKeyId, encrypted) = encryptWith(keyring, code, aadFor(communityId, linkId))
    discard db.execUpdate(
      """update session.links set code_enc = decode($2,'hex'), key_id = $3
         where community_id = $4::uuid and id = $1::uuid""",
      @[textParam(linkId), textParam(bytesHex(encrypted)), textParam(newKeyId),
        textParam(communityId)])
    result.inc
