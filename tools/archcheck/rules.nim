import std/[strutils]

const
  domainTables = ["session.", "player.", "rating.", "tournament.", "community."]
  envAllowlist = [
    "apps/api/src/main.nim",
    "apps/api/src/server.nim",
    "shared/platform-lib/clock.nim",
  ]

proc normalize(path: string): string =
  path.replace('\\', '/')

proc importLines(source: string): seq[(int, string)] =
  let lines = source.splitLines()
  for index in 0 ..< lines.len:
    let trimmed = lines[index].strip()
    if trimmed.startsWith("import ") or trimmed.startsWith("from "):
      result.add((index + 1, trimmed))

proc violationsFor*(path, source: string): seq[string] =
  let file = normalize(path)
  for (lineNumber, line) in importLines(source):
    if file.startsWith("modules/"):
      if line.contains("apps/") or line.contains("mummy"):
        result.add(file & ":" & $lineNumber &
          ": modules must not import the delivery layer (apps/ or mummy)")
      if file.contains("/domain/") and
         (line.contains("db/db") or line.contains("db_connector")):
        result.add(file & ":" & $lineNumber &
          ": domain must not import the database layer")
  let lines = source.splitLines()
  for index in 0 ..< lines.len:
    let trimmed = lines[index].strip()
    if trimmed.startsWith("#"):
      continue
    if (trimmed.contains("now()") or trimmed.contains("times.now(")) and
       file != "shared/platform-lib/clock.nim" and
       not file.contains("/tests/") and not trimmed.contains("default now()"):
      result.add(file & ":" & $(index + 1) & ": use clock.utcNow(), not now()")
    if trimmed.contains("getEnv(") and file notin envAllowlist and
       not file.startsWith("tools/") and not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": environment access is only allowed at the process edge")

  # Community scope for SQL literals written in modules. Multi-line strings are
  # checked as a whole; the rule is intentionally conservative.
  if file.startsWith("modules/"):
    for table in domainTables:
      var offset = 0
      while true:
        let found = source.find(table, offset)
        if found < 0:
          break
        let windowStart = max(0, found - 400)
        let window = source[windowStart ..< min(source.len, found + 400)]
        if not window.contains("community_id"):
          result.add(file & ": SQL touches " & table &
            " without community_id in the surrounding statement")
        offset = found + table.len
