import std/[json, options, os, strutils]
import db/db

const usage = """Usage: ratinglevels <list|set|clear> [options]

  list [--community <slug>]
      Print kind, champion_points, enabled and round_ratios per row.
  set --community <slug> --kind <kind> --champion <number>
      [--enabled true|false] [--ratios '<json>']
      Upsert one ladder row. --ratios is a JSON object of numbers in [0,1];
      omitting it keeps the stored ratios (or {} on a new row).
  clear --community <slug> --kind <kind>
      Delete the row, which returns that kind to the per-game formula.

Kinds: session, tournament_classic, tournament_team.
--dry-run on set/clear prints the plan and writes nothing.
Requires MAJADU_PG_DSN."""

const kinds = ["session", "tournament_classic", "tournament_team"]

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "ratinglevels: " & message
  quit(2)

proc communityIdOf(db: Db, slug: string): string =
  let row = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if row.isNone:
    fail "no community with slug " & slug
  row.get.get("id")

proc requireKind(kind: string) =
  if kind notin kinds:
    fail "unknown kind: " & kind & " (session, tournament_classic, tournament_team)"

proc validateRatios(raw: string): JsonNode =
  try:
    result = parseJson(raw)
  except ValueError as error:
    fail "ratios must be valid JSON: " & error.msg
  if result.kind != JObject:
    fail "ratios must be a JSON object"
  for key, value in result:
    if value.kind notin {JInt, JFloat}:
      fail "ratio " & key & " must be a number"
    let ratio = if value.kind == JInt: value.getInt().float else: value.getFloat()
    if ratio < 0.0 or ratio > 1.0:
      fail "ratio " & key & " must be within [0,1]"

proc existingRow(db: Db, communityId, kind: string): Option[JsonNode] =
  let row = db.queryOne(
    """select round_ratios::text as round_ratios from rating.levels
       where community_id = $1::uuid and kind = $2""",
    @[textParam(communityId), textParam(kind)])
  if row.isSome: some(parseJson(row.get.get("round_ratios"))) else: none(JsonNode)

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let command = paramStr(1)
  var slug, kind, championRaw, ratios = ""
  var enabled = true
  var dryRun = false
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--community":
      index.inc; slug = paramStr(index)
    of "--kind":
      index.inc; kind = paramStr(index)
    of "--champion":
      index.inc; championRaw = paramStr(index)
    of "--enabled":
      index.inc
      case paramStr(index)
      of "true": enabled = true
      of "false": enabled = false
      else: fail "--enabled must be true or false"
    of "--ratios":
      index.inc; ratios = paramStr(index)
    of "--dry-run":
      dryRun = true
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc

  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    fail "MAJADU_PG_DSN is required"
  let db = openDb(dsn, 1)
  defer: db.close()

  case command
  of "list":
    let communityId = if slug.len > 0: communityIdOf(db, slug) else: ""
    let filter = if communityId.len > 0: "where l.community_id = $1::uuid" else: ""
    var items = newJArray()
    for row in db.query(
      """select c.slug as slug, l.kind as kind,
                l.champion_points::text as champion_points,
                l.enabled as enabled, l.round_ratios::text as round_ratios
         from rating.levels l
         join platform.community c on c.id = l.community_id
         """ & filter & """
         order by c.slug, l.kind""",
      if communityId.len > 0: @[textParam(communityId)] else: @[]):
      items.add(%*{"community": row.get("slug"), "kind": row.get("kind"),
        "championPoints": row.get("champion_points"),
        "enabled": row.get("enabled") == "t",
        "roundRatios": parseJson(row.get("round_ratios"))})
    echo $(%*{"items": items})
  of "set":
    if slug.len == 0 or kind.len == 0 or championRaw.len == 0:
      fail "set needs --community, --kind and --champion"
    requireKind(kind)
    var champion = 0.0
    try:
      champion = parseFloat(championRaw)
    except ValueError:
      fail "champion must be a number"
    if champion <= 0:
      fail "champion must be greater than zero"
    if ratios.len > 0:
      discard validateRatios(ratios)
    let communityId = communityIdOf(db, slug)
    let before = existingRow(db, communityId, kind)
    let plannedRatios =
      if ratios.len > 0: validateRatios(ratios)
      elif before.isSome: before.get
      else: newJObject()
    let action = if before.isSome: "update" else: "create"
    if dryRun:
      echo $(%*{"dryRun": true, "action": action, "community": slug,
        "kind": kind, "championPoints": champion,
        "enabled": enabled, "roundRatios": plannedRatios})
      return
    discard db.tx(proc(conn: DbConn): int =
      discard conn.execUpdate(
        """insert into rating.levels
             (community_id, kind, champion_points, round_ratios, enabled,
              updated_at)
           values ($1::uuid, $2, $3::numeric,
                   coalesce(nullif($4::text, '')::jsonb, '{}'::jsonb),
                   $5::boolean, now())
           on conflict (community_id, kind) do update
             set champion_points = excluded.champion_points,
                 round_ratios = case when $4::text = ''
                                     then rating.levels.round_ratios
                                     else excluded.round_ratios end,
                 enabled = excluded.enabled,
                 updated_at = now()""",
        @[textParam(communityId), textParam(kind), textParam(championRaw),
          textParam(ratios), textParam(if enabled: "true" else: "false")])
      1)
    echo $(%*{"community": slug, "kind": kind, "action": action,
      "championPoints": champion, "enabled": enabled,
      "roundRatios": plannedRatios})
  of "clear":
    if slug.len == 0 or kind.len == 0:
      fail "clear needs --community and --kind"
    requireKind(kind)
    let communityId = communityIdOf(db, slug)
    if dryRun:
      let before = existingRow(db, communityId, kind)
      echo $(%*{"dryRun": true, "community": slug, "kind": kind,
        "action": (if before.isSome: "delete" else: "noop")})
      return
    var deleted = 0
    discard db.tx(proc(conn: DbConn): int =
      deleted = conn.execUpdate(
        """delete from rating.levels
           where community_id = $1::uuid and kind = $2""",
        @[textParam(communityId), textParam(kind)])
      1)
    echo $(%*{"community": slug, "kind": kind, "deleted": deleted})
  else:
    fail "unknown command: " & command

when isMainModule:
  main()