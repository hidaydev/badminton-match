import std/[json, options, strutils, unicode]
import db/db
import ./lifecycle

type
  WriteStatus* = enum
    wsOk = "ok"
    wsNotFound = "not found"
    wsStale = "stale"
    wsInvalid = "invalid"
    wsPresetLocked = "preset_locked"

  WriteResult* = object
    status*: WriteStatus
    record*: JsonNode

  SessionPatch* = object
    ## Only the fields a client may change. Everything else is identity or
    ## server-owned, so the SQL can stay a fixed column list.
    title*: Option[string]
    date*: Option[string]
    startTime*: Option[string]
    slotMinutes*: Option[int]
    ## A preset change carries both the id and the frozen rules; the API builds
    ## the rules from the current config, so the write stays a single statement.
    scoringPreset*: Option[string]
    scoringRules*: Option[string]

const sessionColumns = """
       id, title, session_date::text as session_date,
       start_time::text as start_time, slot_minutes, status, version,
       approved_at::text as approved_at"""

const maxTitleLength* = 120

proc parseTitle*(raw: string): string =
  ## A title is shown in the session list and on the live link, so a blank or
  ## whitespace-only one is a data error rather than a valid default.
  result = raw.strip()
  if result.len == 0:
    raise newException(ValueError, "title must not be blank")
  if result.runeLen > maxTitleLength:
    raise newException(ValueError,
      "title must be at most " & $maxTitleLength & " characters")

proc stringField(body: JsonNode, key: string): string =
  ## `getStr` answers its default for a non-string in Nim 2.4, so the kind has
  ## to be checked here: a `null` title used to erase the stored one.
  if body[key].kind != JString:
    raise newException(ValueError, key & " must be a string")
  body[key].getStr()

proc parsePatch*(body: JsonNode): SessionPatch =
  if body.kind != JObject:
    raise newException(ValueError, "patch body must be an object")
  if body.hasKey("title"):
    result.title = some(parseTitle(stringField(body, "title")))
  if body.hasKey("date"):
    result.date = some(stringField(body, "date"))
  if body.hasKey("startTime"):
    result.startTime = some(stringField(body, "startTime"))
  if body.hasKey("slotMinutes"):
    if body["slotMinutes"].kind != JInt:
      raise newException(ValueError, "slotMinutes must be an integer")
    let slot = body["slotMinutes"].getInt()
    if slot < 1 or slot > 240:
      raise newException(ValueError, "slotMinutes must be between 1 and 240")
    result.slotMinutes = some(slot)
  if body.hasKey("scoringPreset"):
    if body["scoringPreset"].kind != JString:
      raise newException(ValueError, "scoringPreset must be a string")
    result.scoringPreset = some(body["scoringPreset"].getStr())

proc sessionNode(row: Row): JsonNode =
  %*{
    "id": row.get("id"),
    "title": row.get("title"),
    "date": row.get("session_date"),
    "startTime": row.get("start_time"),
    "slotMinutes": parseInt(row.get("slot_minutes")),
    "status": row.get("status"),
    "version": parseInt(row.get("version")),
    "approvedAt": if row["approved_at"].isNone: newJNull() else: %row.get("approved_at"),
  }

proc classify(db: Db, communityId, sessionId: string): WriteStatus =
  ## Called only after an UPDATE matched nothing, to tell "gone" from "stale".
  let row = db.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone: wsNotFound else: wsStale

proc dateChangeBlocked(db: Db, communityId, sessionId: string,
                       date: Option[string]): bool =
  ## A rated session's date is part of the result: ingest copied it into
  ## `rating.events.local_date`, and shifting it here would leave the board entry
  ## on the old day. Unlock first (which withdraws the event), change the date,
  ## then lock again.
  ##
  ## The read is a check before the versioned UPDATE, but it cannot go stale in
  ## a harmful way: locking the session bumps its version in the same
  ## transaction, so a concurrent lock makes the UPDATE itself fail as stale.
  if date.isNone:
    return false
  let row = db.queryOne(
    """select approved_at::text as approved_at, status,
              session_date::text as session_date
       from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  row.isSome and isRated(row.get["approved_at"], row.get.get("status")) and
    row.get.get("session_date") != date.get

proc patch*(db: Db, communityId, sessionId: string, expectedVersion: int,
            patch: SessionPatch): WriteResult =
  ## One UPDATE with the version in the predicate: no read-modify-write window
  ## and no delete+insert, so row identity and child rows survive.
  if dateChangeBlocked(db, communityId, sessionId, patch.date):
    return WriteResult(status: wsInvalid)
  if patch.scoringPreset.isSome:
    ## A preset is part of the result, so it freezes once the first set exists.
    ## Clearing the sets is the explicit way back.
    let current = db.queryOne(
      """select s.status,
                exists (select 1 from session.game_sets x
                        where x.community_id = s.community_id
                          and x.session_id = s.id) as has_sets
         from session.sessions s
         where s.community_id = $1::uuid and s.id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    if current.isNone:
      return WriteResult(status: wsNotFound)
    if not isEditable(current.get.get("status")) or
       current.get.get("has_sets") == "t":
      return WriteResult(status: wsPresetLocked)
    if patch.scoringRules.isNone:
      return WriteResult(status: wsInvalid)
  let row = db.queryOne(
    """update session.sessions
       set title = coalesce($3, title),
           session_date = coalesce($4::date, session_date),
           start_time = coalesce($5::time, start_time),
           slot_minutes = coalesce($6, slot_minutes),
           scoring_preset = coalesce($8, scoring_preset),
           scoring_rules = coalesce($9::jsonb, scoring_rules),
           version = version + 1,
           updated_at = now()
       where community_id = $1::uuid and id = $2::uuid and version = $7
       returning""" & sessionColumns,
    @[
      textParam(communityId),
      textParam(sessionId),
      if patch.title.isSome: textParam(patch.title.get) else: nullParam(),
      if patch.date.isSome: textParam(patch.date.get) else: nullParam(),
      if patch.startTime.isSome: textParam(patch.startTime.get) else: nullParam(),
      if patch.slotMinutes.isSome: intParam(patch.slotMinutes.get.int64) else: nullParam(),
      intParam(expectedVersion.int64),
      if patch.scoringPreset.isSome: textParam(patch.scoringPreset.get) else: nullParam(),
      if patch.scoringRules.isSome: textParam(patch.scoringRules.get) else: nullParam(),
    ])
  if row.isSome:
    return WriteResult(status: wsOk, record: sessionNode(row.get))
  WriteResult(status: classify(db, communityId, sessionId))

proc setLock*(db: Db, communityId, sessionId, actorId: string,
              expectedVersion: int, locked: bool): WriteResult =
  ## Locking approves the schedule and stamps who approved it. It deliberately
  ## touches no rating row: ingest is a separate, explicit operation.
  let row = db.queryOne(
    """update session.sessions
       set status = case when $3 then 'locked' else 'draft' end,
           approved_at = case when $3 then now() else null end,
           approved_by = case when $3 then $4::uuid else null end,
           version = version + 1,
           updated_at = now()
       where community_id = $1::uuid and id = $2::uuid and version = $5
       returning""" & sessionColumns,
    @[
      textParam(communityId),
      textParam(sessionId),
      boolParam(locked),
      textParam(actorId),
      intParam(expectedVersion.int64),
    ])
  if row.isSome:
    return WriteResult(status: wsOk, record: sessionNode(row.get))
  WriteResult(status: classify(db, communityId, sessionId))

type
  DeleteStatus* = enum
    dsDeleted = "deleted"
    dsNotFound = "not found"
    dsNotDraft = "not draft"

proc removeConn*(conn: DbConn, communityId, sessionId: string,
                 allowLocked: bool): DeleteStatus =
  ## Hard delete of one session and its children. `session.games` references
  ## `session.participants` without a cascade, so the child rows are removed
  ## explicitly and in dependency order. A locked session is only deletable by
  ## an admin caller (`allowLocked`).
  let row = conn.queryOne(
    """select status from session.sessions
       where community_id = $1::uuid and id = $2::uuid
       for update""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return dsNotFound
  if not isEditable(row.get.get("status")) and not allowLocked:
    return dsNotDraft
  let params = @[textParam(communityId), textParam(sessionId)]
  for statement in [
    """delete from session.games
       where community_id = $1::uuid and session_id = $2::uuid""",
    """delete from session.links
       where community_id = $1::uuid and session_id = $2::uuid""",
    """delete from session.participants
       where community_id = $1::uuid and session_id = $2::uuid"""]:
    discard conn.execUpdate(statement, params)
  discard conn.execUpdate(
    """delete from session.sessions
       where community_id = $1::uuid and id = $2::uuid""", params)
  dsDeleted

proc remove*(db: Db, communityId, sessionId: string,
             allowLocked: bool): DeleteStatus =
  ## One transaction of its own; callers that must also revert the rating event
  ## use `removeConn` inside their transaction instead.
  var outcome = dsDeleted
  discard db.tx(proc(conn: DbConn): int =
    outcome = removeConn(conn, communityId, sessionId, allowLocked)
    1)
  outcome
