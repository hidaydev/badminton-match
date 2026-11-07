import std/[json, options]
import db/db
import ./domain/player

type
  CreateStatus* = enum
    pcOk = "ok"
    pcDuplicate = "duplicate"
    pcInvalid = "invalid"

  CreateResult* = object
    status*: CreateStatus
    player*: JsonNode

  PatchStatus* = enum
    psOk = "ok"
    psNotFound = "not_found"
    psDuplicate = "duplicate"

  PatchResult* = object
    status*: PatchStatus
    player*: JsonNode
    aliasTaken*: bool
      ## Set when the patch asked for aliases that another player already owns.
      ## The whole update was rolled back, so `player` is not what is stored.

const columns = """
  id, canonical_name, gender, tier,
  user_id, created_at::text as created_at, updated_at::text as updated_at"""

const aliasUniqueConstraint = "aliases_key_unique"

const uniqueViolationSqlState = "23505"

proc isUniqueViolation*(error: ref DbError): bool =
  ## A duplicate is a domain result here, not an HTTP status: the patch answers
  ## 200 with a taken alias, and the other callers report `PLAYER_EXISTS` or a
  ## conflict. The boundary owns the status for every duplicate it still sees.
  error.sqlState == uniqueViolationSqlState

proc node*(row: Row): JsonNode =
  %*{
    "id": row.get("id"),
    "name": row.get("canonical_name"),
    "gender": row.get("gender"),
    "tier": if row["tier"].isNone: newJNull() else: %row.get("tier"),
    "userId": if row["user_id"].isNone: newJNull() else: %row.get("user_id"),
    "createdAt": row.get("created_at"),
    "updatedAt": row.get("updated_at"),
  }

proc ownedBy*(db: Db, communityId, userId: string): Option[JsonNode] =
  ## The player bound to this account, if any. One per account per community,
  ## so the limit is the rule, not a page size.
  let row = db.queryOne(
    "select " & columns &
      " from player.players where community_id = $1::uuid and user_id = $2::uuid" &
      " limit 1",
    @[textParam(communityId), textParam(userId)])
  if row.isSome:
    result = some(node(row.get))

proc list*(db: Db, communityId: string, limit: int, cursor = "",
           tier = "", search = ""): seq[JsonNode] =
  ## Keyset pagination on the id keeps the page stable while players are added.
  var params = @[textParam(communityId)]
  var sql = "select " & columns & " from player.players where community_id = $1::uuid"
  if tier.len > 0:
    sql.add(" and tier = $" & $(params.len + 1))
    params.add(textParam(tier))
  if search.len > 0:
    # `strpos` keeps `%` and `_` literal; a name search for "100%" must not
    # match every player. Aliases count as names, so a player imported under an
    # alternate spelling is still found by the canonical one and vice versa.
    let slot = "$" & $(params.len + 1)
    sql.add(" and (strpos(lower(canonical_name), lower(" & slot & ")) > 0" &
      " or exists (select 1 from player.aliases a" &
      " where a.community_id = player.players.community_id" &
      " and a.player_id = player.players.id" &
      " and strpos(lower(a.alias), lower(" & slot & ")) > 0))")
    params.add(textParam(search))
  if cursor.len > 0:
    sql.add(" and id > $" & $(params.len + 1) & "::uuid")
    params.add(textParam(cursor))
  sql.add(" order by id limit $" & $(params.len + 1))
  params.add(intParam(limit.int64))
  for row in db.query(sql, params):
    result.add(node(row))

proc get*(db: Db, communityId, playerId: string): Option[JsonNode] =
  let row = db.queryOne(
    "select " & columns & " from player.players where community_id = $1::uuid and id = $2::uuid",
    @[textParam(communityId), textParam(playerId)])
  if row.isSome: some(node(row.get)) else: none(JsonNode)

proc create*(db: Db, communityId, name, gender: string, tier: string): CreateResult =
  let row = db.queryOne(
    """insert into player.players (community_id, canonical_name, gender, tier)
       values ($1::uuid, $2, $3, nullif($4, '')::text)
       on conflict (community_id, canonical_key) do nothing
       returning""" & columns,
    @[textParam(communityId), textParam(name), textParam(gender), textParam(tier)])
  if row.isSome:
    CreateResult(status: pcOk, player: node(row.get))
  else:
    CreateResult(status: pcDuplicate)

proc playerIdForName*(conn: DbConn, communityId, name: string): string =
  ## Resolves a name to its player for a caller that only has names. Identity
  ## is the generated `canonical_key` column, so both cases fit one statement:
  ## a new name is inserted, an existing one keeps the spelling it was created
  ## with. The no-op update is what makes `returning` fire on the conflict; a
  ## plain `do nothing` would return no row.
  conn.queryOne(
    """insert into player.players (community_id, canonical_name)
       values ($1::uuid, $2)
       on conflict (community_id, canonical_key)
         do update set canonical_name = player.players.canonical_name
       returning id""",
    @[textParam(communityId), textParam(name)]).get.getUuid("id")

proc replaceAliases(conn: DbConn, communityId, playerId: string,
                    values: seq[string]) =
  discard conn.execUpdate(
    """delete from player.aliases
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)])
  for value in values:
    discard conn.execUpdate(
      """insert into player.aliases (community_id, player_id, alias)
         values ($1::uuid, $2::uuid, $3)""",
      @[textParam(communityId), textParam(playerId), textParam(value)])

proc updatePlayer(conn: DbConn, communityId, playerId: string,
                  patch: PlayerPatch): Option[Row] =
  conn.queryOne(
    """update player.players
       set canonical_name = coalesce($3, canonical_name),
           gender = coalesce($4, gender),
           tier = case when $5 then null else coalesce($6, tier) end,
           updated_at = now()
       where community_id = $1::uuid and id = $2::uuid
       returning""" & columns,
    @[
      textParam(communityId),
      textParam(playerId),
      (if patch.name.isSome: textParam(patch.name.get) else: nullParam()),
      (if patch.gender.isSome: textParam($patch.gender.get) else: nullParam()),
      boolParam(patch.clearTier),
      (if patch.tier.isSome: textParam($patch.tier.get) else: nullParam()),
    ])

proc patch*(db: Db, communityId, playerId: string,
            patch: PlayerPatch): PatchResult =
  ## One UPDATE with a fixed column list; `coalesce` keeps untouched fields and
  ## the tier is only cleared when the caller explicitly sent null. Aliases
  ## travel with the row: a patch that names a taken alias rolls the whole
  ## update back instead of leaving a renamed player behind a 409.
  var outcome = PatchResult(status: psNotFound)
  try:
    db.tx(proc(conn: DbConn) =
      let row = updatePlayer(conn, communityId, playerId, patch)
      if row.isNone:
        # A name collision raises above; reaching this point means the row is
        # gone, unless it was replaced after this transaction started.
        let existing = conn.queryOne(
          """select id from player.players
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(playerId)])
        outcome.status = if existing.isSome: psDuplicate else: psNotFound
        return
      outcome = PatchResult(status: psOk, player: node(row.get))
      if patch.aliases.isSome:
        replaceAliases(conn, communityId, playerId, patch.aliases.get))
  except DbError as error:
    if isUniqueViolation(error):
      if error.constraint == aliasUniqueConstraint:
        return PatchResult(status: psOk, aliasTaken: true)
      return PatchResult(status: psDuplicate)
    raise
  outcome

proc aliases*(db: Db, communityId, playerId: string): seq[string] =
  for row in db.query(
    """select alias from player.aliases
       where community_id = $1::uuid and player_id = $2::uuid
       order by alias_key""",
    @[textParam(communityId), textParam(playerId)]):
    result.add(row.get("alias"))

proc setAliases*(db: Db, communityId, playerId: string,
                 values: seq[string]): bool =
  ## Replaces the set inside one transaction. A unique violation means another
  ## player already answers to one of these names; the transaction rolls back,
  ## so the previous set survives unchanged.
  try:
    db.tx(proc(conn: DbConn) =
      replaceAliases(conn, communityId, playerId, values))
    true
  except DbError as error:
    if isUniqueViolation(error):
      return false
    raise

proc remove*(db: Db, communityId, playerId: string): bool =
  db.execUpdate(
    """delete from player.players
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(playerId)]) > 0
