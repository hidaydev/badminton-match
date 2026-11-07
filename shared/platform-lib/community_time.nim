import std/options
import db/db

const validTimezoneSql = "select 1 as ok from pg_timezone_names where name = $1"

proc communityToday*(db: Db, timezone: string): string =
  ## The board window is a calendar question, so "today" is the community's day,
  ## not the server's. One definition serves the API and the snapshot tool.
  let row = db.queryOne(
    "select (now() at time zone $1)::date::text as today",
    @[textParam(timezone)])
  row.get.get("today")

proc validTimezone*(conn: DbConn, timezone: string): bool =
  ## The zone decides which calendar day a session belongs to, so an unknown
  ## name is a bad request, not a value to store and fail on later.
  conn.queryOne(validTimezoneSql, @[textParam(timezone)]).isSome

proc validTimezone*(db: Db, timezone: string): bool =
  db.queryOne(validTimezoneSql, @[textParam(timezone)]).isSome