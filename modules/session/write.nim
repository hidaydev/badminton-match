import std/[json, options, strutils]
import db/db

type
  WriteStatus* = enum
    wsOk = "ok"
    wsNotFound = "not found"
    wsStale = "stale"
    wsInvalid = "invalid"

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

const sessionColumns = """
       id, title, session_date::text as session_date,
       start_time::text as start_time, slot_minutes, status, version,
       approved_at::text as approved_at"""

proc parsePatch*(body: JsonNode): SessionPatch =
  if body.kind != JObject:
    raise newException(ValueError, "patch body must be an object")
  if body.hasKey("title"):
    result.title = some(body["title"].getStr())
  if body.hasKey("date"):
    result.date = some(body["date"].getStr())
  if body.hasKey("startTime"):
    result.startTime = some(body["startTime"].getStr())
  if body.hasKey("slotMinutes"):
    let slot = body["slotMinutes"].getInt()
    if slot < 1 or slot > 240:
      raise newException(ValueError, "slotMinutes must be between 1 and 240")
    result.slotMinutes = some(slot)

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

proc patch*(db: Db, communityId, sessionId: string, expectedVersion: int,
            patch: SessionPatch): WriteResult =
  ## One UPDATE with the version in the predicate: no read-modify-write window
  ## and no delete+insert, so row identity and child rows survive.
  let row = db.queryOne(
    """update session.sessions
       set title = coalesce($3, title),
           session_date = coalesce($4::date, session_date),
           start_time = coalesce($5::time, start_time),
           slot_minutes = coalesce($6, slot_minutes),
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
