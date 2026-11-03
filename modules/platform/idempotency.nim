import std/[json, options, strutils]
import db/db
import sha256

type
  IdempotencyStatus* = enum
    idempotencyNew = "new"
    idempotencyReplay = "replay"
    idempotencyConflict = "conflict"

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
  let row = db.queryOne(
    """select body_hash, status_code, response::text as response
       from platform.idempotency_keys
       where user_id = $1::uuid and key = $2 and expires_at > now()""",
    @[textParam(userId), textParam(key)])
  if row.isSome:
    let value = row.get
    if value.get("body_hash") != bodyDigest:
      return IdempotencyEntry(status: idempotencyConflict)
    return IdempotencyEntry(
      status: idempotencyReplay,
      statusCode: parseInt(value.get("status_code")),
      response: parseJson(value.get("response")),
    )
  discard db.execUpdate(
    """insert into platform.idempotency_keys
         (user_id, key, body_hash, expires_at)
       values ($1::uuid, $2, $3, now() + make_interval(hours => $4))
       on conflict (user_id, key) do nothing""",
    @[textParam(userId), textParam(key), textParam(bodyDigest),
      intParam(ttlHours.int64)])
  IdempotencyEntry(status: idempotencyNew)

proc complete*(db: Db, userId, key: string, statusCode: int,
               response: JsonNode) =
  discard db.execUpdate(
    """update platform.idempotency_keys
       set status_code = $3, response = $4::jsonb
       where user_id = $1::uuid and key = $2""",
    @[textParam(userId), textParam(key), intParam(statusCode.int64),
      textParam($response)])
