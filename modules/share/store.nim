import std/[options, strutils]
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
    startTime*: string
    slotMinutes*: int
    status*: string

  ShareKeyProblem* = object of CatchableError
    ## A live row references a key this process does not hold, which is what a
    ## rotation mistake looks like. The row exists, so the caller must not
    ## answer "no link": that sends the operator to issue a new one instead of
    ## restoring the key.
    linkId*: string

proc keyProblem(linkId: string): ref ShareKeyProblem =
  result = newException(ShareKeyProblem,
    "the live share link references a key the process does not hold")
  result.linkId = linkId

## One definition of "live": a link resolves, is re-displayable, and is watched
## only while this holds. The partial unique index in `0001_core.sql` is looser,
## it only excludes revoked rows, so an expired row must still be revoked to
## free the index.
const liveLinkSql = "revoked_at is null and (expires_at is null or expires_at > now())"

const shareableStatusSql* = "('draft', 'locked', 'published', 'completed')"
  ## What a link may serve: a session that is still in play, whether or not it
  ## has been approved yet. `draft` was excluded until 2026-11-21, which left a
  ## host unable to hand out the link on the day and fill scores in while people
  ## watched; the board a draft shows is still moving, so `draftLinkTtlDays`
  ## bounds how long such a link lives. `archived` means the season is over and
  ## keeps answering through no code.

proc shareable*(status: string): bool =
  ## The Nim form of `shareableStatusSql`, so minting and resolving read one
  ## list instead of two.
  status in ["draft", "locked", "published", "completed"]

const draftLinkTtlDays* = 2
  ## 48 hours, the cap for a link minted while the session is a draft. The
  ## configured `share.link_ttl_days` (30) is the TTL of a link minted once the
  ## session is approved; a draft's schedule is still being edited, so the code
  ## must not outlive the day it was handed out. Finishing the session does not
  ## extend it: rotate the link to get the full TTL.

proc linkTtlDays*(status: string, configuredDays: int): int =
  ## The one place the cap is decided, so a test can hold it without a database.
  if status == "draft": min(configuredDays, draftLinkTtlDays)
  else: configuredDays

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
    raise keyProblem(value.get("id"))

const shareLookupFrom = """
       from session.links l
       join session.sessions s
         on s.community_id = l.community_id and s.id = l.session_id
        and s.status in """ & shareableStatusSql & """
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
  ## The code *is* the credential, so this read happens before any tenant is
  ## known. Under the policy set a plain join here would return nothing and every
  ## live link in every group chat would become a 404, which the call sites read
  ## as "link not found" rather than as a fault.
  ##
  ## Both paths return the same columns: the definer function once step 2
  ## installs it, the join in process before that. The choice is made per call
  ## from the catalogue rather than cached, so a process that started before the
  ## migration cannot keep reading cross-tenant after it.
  var row: Option[Row] = none(Row)
  if db.functionExists("session.share_link_resolve(bytea,uuid)"):
    row = db.queryOne(
      """select link_id, community_id, session_id, key_id, code_enc, title,
                session_date, status, slug, name, timezone, start_time,
                slot_minutes
         from session.share_link_resolve($1, $2)""",
      # The hash goes as 32 raw bytes. Sent as the 64-character hex the server
      # stores 64 bytes in the `bytea`, `code_hash = $1` never matches, and every
      # live link in every group chat answers "link not found".
      @[byteaParam(sha256Raw(code)),
        (if looksLikeUuid(code): textParam(code) else: nullParam())])
  else:
    row = db.queryOne(
      shareLookupColumns & ", to_char(s.start_time, 'HH24:MI') as start_time, s.slot_minutes" & shareLookupFrom &
      """l.code_hash = decode($1,'hex') and """ & liveLinkSql,
      @[textParam(sha256Hex(code))])
    if row.isNone and looksLikeUuid(code):
      # A link minted before the code era was `/s/{sessionId}`. Only those rows
      # answer for an id, so links already in a group chat keep working while a
      # rotated link revokes that shape together with the old code.
      row = db.queryOne(
        shareLookupColumns & ", to_char(s.start_time, 'HH24:MI') as start_time, s.slot_minutes" & shareLookupFrom &
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
    raise keyProblem(value.get("link_id"))
  some(ShareLookup(
    linkId: value.get("link_id"),
    communityId: value.get("community_id"),
    sessionId: value.get("session_id"),
    slug: value.get("slug"),
    communityName: value.get("name"),
    timezone: value.get("timezone"),
    title: value.get("title"),
    sessionDate: value.get("session_date"),
    startTime: value.get("start_time"),
    slotMinutes: parseInt(value.get("slot_minutes")),
    status: value.get("status"),
  ))

proc sessionStatus*(db: Db, communityId, sessionId: string): Option[string] =
  ## A code hands the session to anyone holding it, so minting reads the status
  ## first: a draft must not publish an unfinished schedule for the whole TTL.
  let row = db.queryOne(
    """select status from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isSome: some(row.get.get("status")) else: none(string)

proc unrevokedLinks*(db: Db, communityId, sessionId: string): seq[string] =
  ## Every link the next mint is about to revoke, including an expired row:
  ## `issue` revokes those too, so their watchers have to be closed.
  for row in db.query(
    """select id from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("id"))

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

type
  LegacyRetirement* = object
    ## What one `retireLegacy` run did. `bounded` rows used to be live forever
    ## and now carry an expiry; `retired` rows no longer answer for their
    ## session id.
    bounded*: int
    retired*: int

proc communityIds(db: Db): seq[string] =
  ## Every tenant, read from the one table that carries no policy. A key is
  ## shared by the whole deployment and a legacy link can live in any community,
  ## so the affected row set is every tenant, not one the caller names.
  ##
  ## The rows themselves are then read and written through a facade that
  ## declares one community: on the plain pool under the 0061 policy set a
  ## `select` from `session.links` returns nothing, so the old code counted zero
  ## links and reported success while touching none of them.
  for row in db.query("select id from platform.community order by slug"):
    result.add(row.get("id"))

proc retireLegacy*(db: Db, windowDays: int, dryRun = false): LegacyRetirement =
  ## Gives the pre-code shortcut a sunset. 0033 marked every row that existed
  ## when codes landed, and `expires_at is null` means "live forever", so the
  ## session id was a permanent public capability: every member sees it in URLs
  ## and payloads, and a removed member keeps reading through it.
  ##
  ## One run bounds those rows to `windowDays` from now and clears the shortcut
  ## on rows whose window has passed (or whose link is already expired), so a
  ## second run leaves nothing to retire. `dryRun` counts without writing, which
  ## is what an operator needs before a cutover.
  if windowDays < 1:
    raise newException(ValueError, "windowDays must be at least 1")
  let openSql = """from session.links
    where legacy_id_ok and expires_at is null"""
  let staleSql = """from session.links
    where legacy_id_ok
      and (expires_at is null or expires_at <= now()
           or created_at < now() - make_interval(days => $1))"""
  for communityId in communityIds(db):
    let scoped = db.scoped(communityId)
    if dryRun:
      result.bounded += scoped.queryOne(
        "select count(*)::int as n " & openSql).get.getInt("n")
      result.retired += scoped.queryOne(
        "select count(*)::int as n " & staleSql,
        @[intParam(windowDays.int64)]).get.getInt("n")
      continue
    # Bound first: the update is idempotent because the predicate requires a NULL
    # expiry, so a second run finds nothing to do.
    result.bounded += scoped.execUpdate(
      """update session.links
         set expires_at = now() + make_interval(days => $1)
         where legacy_id_ok and expires_at is null""",
      @[intParam(windowDays.int64)])
    result.retired += scoped.execUpdate(
      """update session.links set legacy_id_ok = false
         where legacy_id_ok
           and (expires_at is null or expires_at <= now()
                or created_at < now() - make_interval(days => $1))""",
      @[intParam(windowDays.int64)])

proc rotateKeys*(db: Db, keyring: Keyring, fromKeyId, toKeyId: string,
                 dryRun = false): int =
  ## Rotating the *key*: every link still sealed with `fromKeyId` is re-encrypted
  ## under `toKeyId` with a fresh nonce. Rows already on the target key are
  ## skipped, so running it twice changes nothing the second time.
  ##
  ## The target is the key the operator named, never the active one: sealing
  ## under the active key while printing another target let an operator retire a
  ## key that was still in use. A target the keyring does not hold is refused
  ## before the first write. `dryRun` reports the exact row count and writes
  ## nothing.
  ##
  ## The count matters more than the write: `--dry-run` is the pre-flight an
  ## operator reads before retiring a key, and `SHARE_CODE_KEYS` is the only copy
  ## of it. A read on the plain pool returned zero under the policy set, so the
  ## pre-flight said "nothing uses this key" while links still did.
  if fromKeyId == toKeyId:
    return 0
  if not keyring.holds(toKeyId):
    raise newException(ShareKeyError,
      "target share key is missing from SHARE_CODE_KEYS: " & toKeyId)
  for communityId in communityIds(db):
    let scoped = db.scoped(communityId)
    let rows = scoped.query(
      """select id, community_id, key_id, encode(code_enc,'hex') as code_enc
         from session.links
         where community_id = $1::uuid and key_id = $2""",
      @[textParam(communityId), textParam(fromKeyId)])
    if dryRun:
      result += rows.len
      continue
    for row in rows:
      let linkId = row.get("id")
      var code = ""
      try:
        code = decryptWith(keyring, fromKeyId, hexBytes(row.get("code_enc")),
          aadFor(communityId, linkId))
      except ShareKeyError:
        continue
      let (newKeyId, encrypted) = encryptWithKey(keyring, toKeyId, code,
        aadFor(communityId, linkId))
      discard scoped.execUpdate(
        """update session.links set code_enc = decode($2,'hex'), key_id = $3
           where community_id = $4::uuid and id = $1::uuid""",
        @[textParam(linkId), textParam(bytesHex(encrypted)), textParam(newKeyId),
          textParam(communityId)])
      result.inc
