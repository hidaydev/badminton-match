import std/[options, os, times]

proc forcedNow*(): Option[DateTime] =
  ## MAJADU_NOW pins the clock for tests and replays. Only RFC 3339 UTC with a
  ## trailing Z is accepted; anything else refuses to start.
  let raw = getEnv("MAJADU_NOW")
  if raw.len == 0:
    return none(DateTime)
  try:
    some(parse(raw, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()))
  except TimeParseError:
    raise newException(ValueError, "MAJADU_NOW must be RFC 3339 UTC, e.g. 2026-11-03T12:00:00Z")

proc utcNow*(): DateTime =
  ## The only clock the application may use.
  let forced = forcedNow()
  if forced.isSome:
    forced.get
  else:
    now().utc

proc utcNowMillis*(): int64 =
  ## Milliseconds since the epoch from the same clock, so a pinned MAJADU_NOW
  ## also orders uuidv7 ids against the pinned instant.
  let moment = utcNow()
  moment.toTime.toUnix * 1000 + int64(moment.nanosecond div 1_000_000)
