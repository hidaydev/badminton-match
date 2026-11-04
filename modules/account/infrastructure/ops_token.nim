import std/[options, strutils, sysrand]
import db/db
import sha256

type
  Token* = object
    id*: string
    name*: string
    createdAt*: string
    expiresAt*: string
    revokedAt*: string

proc newToken(): string =
  var bytes = newSeq[byte](32)
  if not urandom(bytes):
    raise newException(IOError, "no entropy available")
  for byte in bytes:
    result.add(toHex(byte, 2).toLowerAscii())

proc issue*(db: Db, name, createdBy: string, ttlDays: int): string =
  ## Returns the plaintext exactly once; the row keeps only the hash.
  let token = newToken()
  discard db.execUpdate(
    """insert into platform.ops_token
         (name, token_hash, created_by, expires_at)
       values ($1, decode($2,'hex'), nullif($3, '')::uuid,
               case when $4 > 0 then now() + make_interval(days => $4) else null end)""",
    @[
      textParam(name),
      textParam(sha256Hex(token)),
      textParam(createdBy),
      intParam(ttlDays.int64),
    ])
  token

proc verify*(db: Db, token: string): Option[string] =
  ## Returns the token name when it is active. Expiry is evaluated by the
  ## database so a clock skew on the process cannot extend a token's life.
  if token.len == 0:
    return none(string)
  let row = db.queryOne(
    """update platform.ops_token
       set last_used_at = now()
       where token_hash = decode($1,'hex')
         and revoked_at is null
         and (expires_at is null or expires_at > now())
       returning name""",
    @[textParam(sha256Hex(token))])
  if row.isSome: some(row.get.get("name")) else: none(string)

proc revokeToken*(db: Db, tokenId: string): bool =
  db.execUpdate(
    """update platform.ops_token set revoked_at = now()
       where id = $1::uuid and revoked_at is null""",
    @[textParam(tokenId)]) > 0

proc list*(db: Db): seq[Token] =
  for row in db.query(
    """select id, name, created_at::text as created_at,
              coalesce(expires_at::text, '') as expires_at,
              coalesce(revoked_at::text, '') as revoked_at
       from platform.ops_token order by created_at desc"""):
    result.add(Token(id: row.get("id"), name: row.get("name"),
      createdAt: row.get("created_at"), expiresAt: row.get("expires_at"),
      revokedAt: row.get("revoked_at")))
