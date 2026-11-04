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

proc aadFor(communityId, linkId: string): string =
  ## Binds a ciphertext to the exact row and community it was minted for.
  communityId & "|" & linkId

proc issue*(db: Db, keyring: Keyring, communityId, sessionId,
            createdBy: string): string =
  ## Rotating the *link*: the previous live code stops resolving in the same
  ## transaction because a partial unique index allows only one live row.
  let linkId = uuidv7()
  let code = newShareCode()
  let (keyId, encrypted) = encryptWith(keyring, code, aadFor(communityId, linkId))
  discard db.tx(proc(conn: DbConn): int =
    discard conn.execUpdate(
      """update session.links set revoked_at = now()
         where community_id = $2::uuid and session_id = $1::uuid
           and revoked_at is null""",
      @[textParam(sessionId), textParam(communityId)])
    discard conn.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_by)
         values ($1::uuid, $2::uuid, $3::uuid, decode($4,'hex'), decode($5,'hex'),
                 $6, $7::uuid)""",
      @[textParam(linkId), textParam(communityId), textParam(sessionId),
        textParam(sha256Hex(code)), textParam(bytesHex(encrypted)),
        textParam(keyId), textParam(createdBy)])
    1)
  code

proc currentCode*(db: Db, keyring: Keyring, communityId,
                  sessionId: string): Option[string] =
  ## Re-display for a host or admin. The caller audits the read; the code itself
  ## never leaves this row in any other response.
  let row = db.queryOne(
    """select id, key_id, encode(code_enc,'hex') as code_enc
       from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return none(string)
  let value = row.get
  try:
    some(decryptWith(keyring, value.get("key_id"),
      hexBytes(value.get("code_enc")), aadFor(communityId, value.get("id"))))
  except ShareKeyError:
    none(string)

proc resolve*(db: Db, keyring: Keyring, code: string): Option[ShareLookup] =
  let row = db.queryOne(
    """select l.id as link_id, l.community_id, l.key_id, l.session_id,
              encode(l.code_enc,'hex') as code_enc,
              s.title, s.session_date::text as session_date, s.status,
              c.slug, c.name, c.timezone
       from session.links l
       join session.sessions s
         on s.community_id = l.community_id and s.id = l.session_id
       join platform.community c on c.id = l.community_id
       where l.code_hash = decode($1,'hex') and l.revoked_at is null""",
    @[textParam(sha256Hex(code))])
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

proc revokeLive*(db: Db, communityId, sessionId: string): seq[string] =
  ## Revokes every live link for the session and returns their ids so the
  ## caller can drop the watchers and their tickets. An empty result means
  ## there was nothing to revoke.
  for row in db.query(
    """update session.links set revoked_at = now()
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null
       returning id""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("id"))

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
