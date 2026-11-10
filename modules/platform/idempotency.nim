import std/[json, options, strutils]
import db/db
import sha256

type
  IdempotencyStatus* = enum
    idempotencyNew = "new"
    idempotencyReplay = "replay"
    idempotencyConflict = "conflict"
    idempotencyInProgress = "in_progress"
    ## The key is owned by a request that has not finished. It is not a
    ## conflict: the body may be identical, and the retry is legitimate.

  IdempotencyEntry* = object
    status*: IdempotencyStatus
    statusCode*: int
    response*: JsonNode

proc bodyHash*(body: string): string =
  sha256Hex(body)

proc scopedKey*(communityId, key: string): string =
  ## Keys are scoped per community so two communities cannot collide, and the
  ## stored unique index stays `(user_id, key)`.
  if communityId.len == 0:
    return key
  communityId & ":" & key

proc claim*(db: Db, userId, key, bodyDigest: string,
            ttlHours = 24): IdempotencyEntry =
  ## Returns `idempotencyNew` when the caller owns the key and must do the work.
  ## A replay of the same body returns the stored response; the same key with a
  ## different body is a conflict (409) and never overwrites the first result.
  ##
  ## The claim is one statement so parallel requests cannot both win: the insert
  ## only replaces an expired row, and a live row is left untouched.
  let claimed = db.queryOne(
    """insert into platform.idempotency_keys
         (user_id, key, body_hash, expires_at)
       values ($1::uuid, $2, $3, now() + make_interval(hours => $4))
       on conflict (user_id, key) do update
         set body_hash = excluded.body_hash,
             status_code = null,
             response = null,
             expires_at = excluded.expires_at
         where platform.idempotency_keys.expires_at <= now()
       returning body_hash, status_code, response::text as response""",
    @[textParam(userId), textParam(key), textParam(bodyDigest),
      intParam(ttlHours.int64)])
  if claimed.isSome:
    return IdempotencyEntry(status: idempotencyNew)

  # The insert conflicted with a live row. Reading it is safe: the row cannot
  # expire between the conflict and this statement without another claim first
  # replacing it, and that claim owns the key.
  let live = db.queryOne(
    """select body_hash, status_code, response::text as response
       from platform.idempotency_keys
       where user_id = $1::uuid and key = $2""",
    @[textParam(userId), textParam(key)])
  if live.isNone or live.get.get("body_hash") != bodyDigest:
    return IdempotencyEntry(status: idempotencyConflict)
  let value = live.get
  if value["status_code"].isNone or value["response"].isNone:
    # Another request claimed the key but has not finished yet. The body may be
    # identical, so this is not the body-mismatch conflict: a caller that retries
    # after a short wait gets the stored response instead of a false accusation.
    return IdempotencyEntry(status: idempotencyInProgress)
  IdempotencyEntry(
    status: idempotencyReplay,
    statusCode: parseInt(value.get("status_code")),
    response: parseJson(value.get("response")),
  )

proc complete*(db: Db, userId, key: string, statusCode: int,
               response: JsonNode) =
  discard db.execUpdate(
    """update platform.idempotency_keys
       set status_code = $3, response = $4::jsonb
       where user_id = $1::uuid and key = $2""",
    @[textParam(userId), textParam(key), intParam(statusCode.int64),
      textParam($response)])

proc release*(db: Db, userId, key: string) =
  ## A failed attempt must not own the key: the retry with a corrected body
  ## would otherwise answer 409 for the rest of the TTL.
  discard db.execUpdate(
    """delete from platform.idempotency_keys
       where user_id = $1::uuid and key = $2""",
    @[textParam(userId), textParam(key)])
