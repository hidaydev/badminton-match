import std/[json, options, os, strutils, tables]
import cli
import community_time
import db/db
import platform/config/store
import rating/infrastructure/params
import rating/read

const
  program = "ranksnapshot"
  usage = """Usage: ranksnapshot [--as-of YYYY-MM-DD]

Writes one rating.snapshots row per player on today's board, for every
community. Re-running on the same day overwrites instead of duplicating.

Requires MAJADU_PG_DSN; the community timezone decides what "today" is."""

proc communitySettings(db: Db, communityId: string): JsonNode =
  let row = db.queryOne(
    """select values::text as values from community.settings
       where community_id = $1::uuid""", @[textParam(communityId)])
  if row.isSome: parseJson(row.get.get("values")) else: newJObject()

proc main() =
  var asOf = ""
  if paramCount() == 2 and paramStr(1) == "--as-of":
    asOf = paramStr(2)
  elif paramCount() > 0:
    echo usage
    quit(2)
  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()

  let snapshot = loadSnapshot(db)
  let limit = snapshot.values[$keyRankBoardLimit].getInt()
  var communities, players = 0
  for row in db.query("select id, timezone from platform.community order by slug"):
    let communityId = row.get("id")
    let settings = communitySettings(db, communityId)
    let params = loadRatingParams(snapshot, settings)
    let latest = latestEventDate(db, communityId)
    let day =
      if asOf.len > 0: asOf
      elif latest.len > 0: latest
      else: communityToday(db, row.get("timezone"))
    let rows = board(db, BoardQuery(communityId: communityId, asOf: day,
      params: params, limit: limit, tier: ""))
    discard writeSnapshot(db, communityId, day, rows)
    inc communities
    players += rows.len
  echo $(%*{"communities": communities, "rows": players})

when isMainModule:
  main()
