## One-time import from the v1 database (`bm_staging`) into v2.
##
## Run once at cutover and again if it fails halfway: every row written here has
## an entry in `import.row_map`, and a rerun reads that map instead of minting a
## second set of ids. The target write happens in one transaction; the source is
## only ever read.
##
##   import etl    --source <v1 dsn> --target <v2 dsn> --slug majadu --name Majadu
##   import verify --source <v1 dsn> --target <v2 dsn>
##
## Domains not imported yet are printed as skipped instead of being silently
## ignored: a report that claims zero differences across the whole database
## while half of it stayed behind would be worse than no report.

import std/[json, options, os, tables]
import db/db
import uuidv7
import platform/config/registry

type
  Dsn* = object
    source*: string
    target*: string

  Result* = object
    created*: int
    updated*: int
    collapsed*: int
    skipped*: int

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "import: " & message
  quit(2)

proc parseArgs(): tuple[command: string, dsn: Dsn, slug, name, timezone: string,
                        dryRun: bool] =
  result.command = "etl"
  if paramCount() >= 1:
    result.command = paramStr(1)
    if result.command notin ["etl", "verify"]:
      fail "unknown command " & result.command & " (etl|verify)"
  result.dsn.source = getEnv("MAJADU_ETL_SOURCE_DSN")
  result.dsn.target = getEnv("MAJADU_PG_DSN")
  result.slug = getEnv("MAJADU_IMPORT_SLUG")
  result.name = getEnv("MAJADU_IMPORT_NAME")
  result.timezone = getEnv("MAJADU_IMPORT_TIMEZONE")
  var index = 2
  while index <= paramCount():
    let flag = paramStr(index)
    let hasValue = index + 1 <= paramCount()
    case flag
    of "--source":
      if not hasValue: fail "--source needs a value"
      inc index; result.dsn.source = paramStr(index)
    of "--target":
      if not hasValue: fail "--target needs a value"
      inc index; result.dsn.target = paramStr(index)
    of "--slug":
      if not hasValue: fail "--slug needs a value"
      inc index; result.slug = paramStr(index)
    of "--name":
      if not hasValue: fail "--name needs a value"
      inc index; result.name = paramStr(index)
    of "--timezone":
      if not hasValue: fail "--timezone needs a value"
      inc index; result.timezone = paramStr(index)
    of "--dry-run":
      result.dryRun = true
    else:
      fail "unknown argument " & flag
    inc index
  if result.dsn.source.len == 0:
    fail "MAJADU_ETL_SOURCE_DSN or --source is required"
  if result.dsn.target.len == 0:
    fail "MAJADU_PG_DSN or --target is required"

proc configString(db: Db, key: string): Option[string] =
  let row = db.queryOne(
    "select value #>> '{}' as value from platform.config where key = $1",
    @[textParam(key)])
  if row.isSome: some(row.get.get("value")) else: none(string)

proc resolveCommunity(db: Db, slug, name, timezone: string,
                      dryRun: bool): string =
  ## The v1 database has no communities; the import puts everything in one. A
  ## rerun with the same slug finds it and changes nothing.
  let id = getEnv("MAJADU_IMPORT_COMMUNITY_ID")
  if id.len > 0:
    let found = db.queryOne("select id from platform.community where id = $1::uuid",
      @[textParam(id)])
    if found.isNone: fail "MAJADU_IMPORT_COMMUNITY_ID names no community"
    return found.get.get("id")
  if slug.len == 0:
    fail "--slug is required (or MAJADU_IMPORT_SLUG)"
  let existing = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if existing.isSome:
    return existing.get.get("id")
  if name.len == 0:
    fail "--name is required when the community does not exist yet"
  var zone = timezone
  if zone.len == 0:
    let configured = configString(db, $keyCommunityDefaultTimezone)
    if configured.isNone:
      fail "no --timezone and community.default_timezone is not configured"
    zone = configured.get
  if dryRun:
    return "00000000-0000-0000-0000-000000000000"
  let created = db.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ($1, $2, $3) returning id""",
    @[textParam(slug), textParam(name), textParam(zone)])
  created.get.get("id")

proc mapLookup(conn: DbConn, communityId, entity, oldId: string): Option[string] =
  let row = conn.queryOne(
    """select new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = $2 and old_id = $3""",
    @[textParam(communityId), textParam(entity), textParam(oldId)])
  if row.isSome: some(row.get.get("new_id")) else: none(string)

proc mapPut(conn: DbConn, communityId, entity, oldId, newId: string) =
  discard conn.execUpdate(
    """insert into import.row_map (community_id, entity, old_id, new_id)
       values ($1::uuid, $2, $3, $4::uuid)
       on conflict (community_id, entity, old_id)
       do update set new_id = excluded.new_id""",
    @[textParam(communityId), textParam(entity), textParam(oldId),
      textParam(newId)])

proc importPlayers(source, target: Db, communityId: string, dryRun: bool): Result =
  ## `canonical_name` is unique per community in v2 but not in v1. Two v1 rows
  ## with the same name collapse into one player; the second old id is mapped to
  ## the first new id, which is what "collapsed" counts.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select id::text as id, canonical_name, coalesce(tier, '') as tier,
                gender, created_at::text as created_at,
                updated_at::text as updated_at
         from bm.players order by created_at, id"""):
      let oldId = row.get("id")
      let mapped = mapLookup(conn, communityId, "player", oldId)
      if dryRun:
        inc stats.created
        continue
      if mapped.isSome:
        let present = conn.queryOne(
          "select 1 as ok from player.players where community_id = $1::uuid and id = $2::uuid",
          @[textParam(communityId), textParam(mapped.get)])
        if present.isSome:
          discard conn.execUpdate(
            """update player.players
               set canonical_name = $3, tier = nullif($4, ''), gender = $5,
                   updated_at = $6::timestamptz
               where community_id = $1::uuid and id = $2::uuid""",
            @[textParam(communityId), textParam(mapped.get),
              textParam(row.get("canonical_name")), textParam(row.get("tier")),
              textParam(row.get("gender")), textParam(row.get("updated_at"))])
          inc stats.updated
          continue
      let inserted = conn.queryOne(
        """insert into player.players
             (id, community_id, canonical_name, tier, gender, created_at, updated_at)
           values ($1::uuid, $2::uuid, $3, nullif($4, ''), $5,
                   $6::timestamptz, $7::timestamptz)
           on conflict (community_id, canonical_key) do update
             set updated_at = player.players.updated_at
           returning id::text as id""",
        @[textParam(uuidv7()), textParam(communityId),
          textParam(row.get("canonical_name")), textParam(row.get("tier")),
          textParam(row.get("gender")), textParam(row.get("created_at")),
          textParam(row.get("updated_at"))])
      let newId = inserted.get.get("id")
      if mapped.isSome and mapped.get != newId:
        inc stats.collapsed
      else:
        inc stats.created
      mapPut(conn, communityId, "player", oldId, newId)
    1)
  stats

proc importAliases(source, target: Db, communityId: string,
                   dryRun: bool): Result =
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select a.alias_name, a.player_id::text as player_id,
                a.created_at::text as created_at
         from bm.player_aliases a order by a.created_at, a.alias_name"""):
      let player = mapLookup(conn, communityId, "player", row.get("player_id"))
      if player.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let changed = conn.execUpdate(
        """insert into player.aliases (community_id, player_id, alias, created_at)
           values ($1::uuid, $2::uuid, $3, $4::timestamptz)
           on conflict (community_id, alias_key) do nothing""",
        @[textParam(communityId), textParam(player.get), textParam(row.get("alias_name")),
          textParam(row.get("created_at"))])
      if changed == 1: inc stats.created else: inc stats.updated
    1)
  stats

proc importEtl*(source, target: Db, slug, name, timezone: string,
                dryRun: bool): tuple[players, aliases: Result] =
  let communityId = resolveCommunity(target, slug, name, timezone, dryRun)
  let players = importPlayers(source, target, communityId, dryRun)
  let aliases = importAliases(source, target, communityId, dryRun)
  result = (players: players, aliases: aliases)
  echo $(%*{
    "communityId": communityId,
    "dryRun": dryRun,
    "players": %*{"created": players.created, "updated": players.updated,
                  "collapsed": players.collapsed},
    "aliases": %*{"created": aliases.created, "updated": aliases.updated,
                  "skipped": aliases.skipped},
    "skippedDomains": %["sessions", "rating", "tournaments", "achievements",
                        "snapshots"]})

proc verifyPlayers*(source, target: Db, communityId: string): seq[string] =
  ## Compares the mapped rows field by field. Counts alone would hide a rename
  ## and would make a collapsed duplicate look like a missing row.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")
  if oldToNew.len == 0:
    return @["no player has been imported into this community"]

  var byId = initTable[string, Row]()
  for row in target.query(
    """select id::text as id, canonical_name, coalesce(tier, '') as tier, gender
       from player.players where community_id = $1::uuid""",
    @[textParam(communityId)]):
    byId[row.get("id")] = row

  for row in source.query(
    """select id::text as id, canonical_name, coalesce(tier, '') as tier, gender
       from bm.players order by id"""):
    let newId = oldToNew.getOrDefault(row.get("id"))
    if newId.len == 0:
      result.add "v1 player " & row.get("id") & " has no mapping"
      continue
    if not byId.hasKey(newId):
      result.add "mapped player " & newId & " is missing from v2"
      continue
    let ours = byId[newId]
    if ours.get("canonical_name") != row.get("canonical_name"):
      result.add "name differs for v1 player " & row.get("id")
    if ours.get("tier") != row.get("tier") or ours.get("gender") != row.get("gender"):
      result.add "tier or gender differs for v1 player " & row.get("id")

proc verifyAliases*(source, target: Db, communityId: string): seq[string] =
  let mapped = target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)])
  var oldToNew = initTable[string, string]()
  for row in mapped: oldToNew[row.get("old_id")] = row.get("new_id")
  for row in source.query(
    """select alias_name, player_id::text as player_id from bm.player_aliases"""):
    let newId = oldToNew.getOrDefault(row.get("player_id"))
    if newId.len == 0:
      result.add "v1 alias " & row.get("alias_name") & " has no mapped player"
      continue
    let found = target.queryOne(
      """select 1 as ok from player.aliases
         where community_id = $1::uuid and player_id = $2::uuid
           and alias_key = btrim(regexp_replace(lower($3), '\s+', ' ', 'g'))""",
      @[textParam(communityId), textParam(newId), textParam(row.get("alias_name"))])
    if found.isNone:
      result.add "alias " & row.get("alias_name") & " did not reach v2"

proc verifyEtl(source, target: Db, slugArg: string) =
  let communityId = getEnv("MAJADU_IMPORT_COMMUNITY_ID")
  var resolved = communityId
  if resolved.len == 0:
    let slug = if slugArg.len > 0: slugArg else: getEnv("MAJADU_IMPORT_SLUG")
    if slug.len == 0:
      fail "verify needs MAJADU_IMPORT_SLUG or MAJADU_IMPORT_COMMUNITY_ID"
    let row = target.queryOne(
      "select id::text as id from platform.community where slug = $1",
      @[textParam(slug)])
    if row.isNone: fail "community " & slug & " does not exist"
    resolved = row.get.get("id")

  var problems = verifyPlayers(source, target, resolved)
  problems.add verifyAliases(source, target, resolved)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "import: " & problem
    echo $(%*{"communityId": resolved, "problems": problems.len})
    quit(1)
  echo $(%*{"communityId": resolved, "problems": 0,
            "checkedDomains": %["players", "aliases"],
            "uncheckedDomains": %["sessions", "rating", "tournaments",
                                  "achievements", "snapshots"]})

proc main() =
  let args = parseArgs()
  let source = openDb(args.dsn.source, 1)
  defer: source.close()
  let target = openDb(args.dsn.target, 1)
  defer: target.close()
  case args.command
  of "etl":
    discard importEtl(source, target, args.slug, args.name, args.timezone,
      args.dryRun)
  of "verify":
    verifyEtl(source, target, args.slug)
  else:
    fail "unknown command " & args.command

when isMainModule:
  main()
