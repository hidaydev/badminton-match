import std/[json, options, os, strutils]
import cli
import db/db

const
  program = "ratinglevels"
  usage = """Usage: ratinglevels <list|set|clear> [options]

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

proc communityIdOf(db: Db, slug: string): string =
  let row = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if row.isNone:
    fail(program, "no community with slug " & slug)
  row.get.get("id")

proc requireKind*(kind: string) =
  ## Exported for `tests/levels_test.nim` (D-5): the accepted kinds are a
  ## command-line contract, and the test states it instead of repeating it.
  if kind notin kinds:
    fail(program, "unknown kind: " & kind &
      " (session, tournament_classic, tournament_team)")

proc validateRatios*(raw: string): JsonNode =
  ## Exported for `tests/levels_test.nim` (D-5): the shape a ladder row accepts
  ## is a rule of its own, and a refused value ends the process, so a suite can
  ## only assert the accepted half in-process.
  try:
    result = parseJson(raw)
  except ValueError as error:
    fail(program, "ratios must be valid JSON: " & error.msg)
  if result.kind != JObject:
    fail(program, "ratios must be a JSON object")
  for key, value in result:
    if value.kind notin {JInt, JFloat}:
      fail(program, "ratio " & key & " must be a number")
    let ratio = if value.kind == JInt: value.getInt().float else: value.getFloat()
    if ratio < 0.0 or ratio > 1.0:
      fail(program, "ratio " & key & " must be within [0,1]")

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
  for (flag, value) in flags(program, 2,
      ["--community", "--kind", "--champion", "--enabled", "--ratios"]):
    case flag
    of "--community":
      slug = value
    of "--kind":
      kind = value
    of "--champion":
      championRaw = value
    of "--enabled":
      case value
      of "true": enabled = true
      of "false": enabled = false
      else: fail(program, "--enabled must be true or false")
    of "--ratios":
      ratios = value
    of "--dry-run":
      dryRun = true
    else:
      usageFail(program, "unknown argument: " & flag)

  # The command's own arguments are checked before the database is opened, so a
  # bad line is refused even when MAJADU_PG_DSN is missing, and the exit code
  # describes the line rather than the environment. Exit codes and messages for
  # a valid line are unchanged.
  var champion = 0.0
  case command
  of "set":
    if slug.len == 0 or kind.len == 0 or championRaw.len == 0:
      usageFail(program, "set needs --community, --kind and --champion")
    requireKind(kind)
    try:
      champion = parseFloat(championRaw)
    except ValueError:
      fail(program, "champion must be a number")
    if champion <= 0:
      fail(program, "champion must be greater than zero")
    if ratios.len > 0:
      discard validateRatios(ratios)
  of "clear":
    if slug.len == 0 or kind.len == 0:
      usageFail(program, "clear needs --community and --kind")
    requireKind(kind)
  of "list":
    discard
  else:
    usageFail(program, "unknown command: " & command)

  let db = openDb(dsnOrFail(program), 1)
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
    db.tx(proc(conn: DbConn) =
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
    )
    echo $(%*{"community": slug, "kind": kind, "action": action,
      "championPoints": champion, "enabled": enabled,
      "roundRatios": plannedRatios})
  of "clear":
    let communityId = communityIdOf(db, slug)
    if dryRun:
      let before = existingRow(db, communityId, kind)
      echo $(%*{"dryRun": true, "community": slug, "kind": kind,
        "action": (if before.isSome: "delete" else: "noop")})
      return
    var deleted = 0
    db.tx(proc(conn: DbConn) =
      deleted = conn.execUpdate(
        """delete from rating.levels
           where community_id = $1::uuid and kind = $2""",
        @[textParam(communityId), textParam(kind)])
    )
    echo $(%*{"community": slug, "kind": kind, "deleted": deleted})
  else:
    # The command was accepted above, so this branch is unreachable; the case
    # keeps an else because a string case must be exhaustive.
    discard

when isMainModule:
  main()