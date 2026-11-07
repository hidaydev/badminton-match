import std/[strutils]

const
  domainTables = ["session.", "player.", "rating.", "tournament.", "community."]
  # `cli.nim` is the process edge for every tool: `dsnOrFail` reads the DSN that
  # used to be read in sixteen `main.nim` files.
  envAllowlist = ["shared/platform-lib/clock.nim", "shared/platform-lib/cli.nim"]

proc envAllowed(file: string): bool =
  ## Environment reads belong to the process edge (apps/, tools/) and to
  ## infrastructure adapters that build their configuration from it.
  file.startsWith("apps/") or file.startsWith("tools/") or
    file in envAllowlist or file.contains("/infrastructure/")

proc stripStrings(lines: seq[string]): seq[string] =
  ## Removes string literal contents (both "..." and triple-quoted blocks) so SQL
  ## `now()` and `?` are not mistaken for Nim code.
  var triple = false
  var quoted = false
  for line in lines:
    var rendered = ""
    var index = 0
    while index < line.len:
      let c = line[index]
      if triple:
        if index + 2 < line.len and c == '"' and line[index + 1] == '"' and
           line[index + 2] == '"':
          triple = false
          index += 3
        else:
          index.inc
      elif quoted:
        if c == '\\':
          index += 2
        elif c == '"':
          quoted = false
          index.inc
        else:
          index.inc
      elif index + 2 < line.len and c == '"' and line[index + 1] == '"' and
           line[index + 2] == '"':
        triple = true
        index += 3
      elif c == '"':
        quoted = true
        index.inc
      else:
        rendered.add(c)
        index.inc
    result.add(rendered)

proc literalEnd(source: string, start: int): int =
  ## Index just past the literal that opens at `start`, which is a double quote.
  if start + 2 < source.len and source[start + 1] == '"' and
     source[start + 2] == '"':
    var index = start + 3
    while index + 2 < source.len:
      if source[index] == '"' and source[index + 1] == '"' and
         source[index + 2] == '"':
        return index + 3
      inc index
    return source.len
  var index = start + 1
  while index < source.len and source[index] != '"':
    if source[index] == '\\' and index + 1 < source.len:
      inc index
    inc index
  if index < source.len:
    inc index
  index

proc literalBody(source: string, start, finish: int): string =
  let triple = start + 2 < finish and source[start + 1] == '"' and
               source[start + 2] == '"'
  let first = start + (if triple: 3 else: 1)
  let last = finish - (if triple: 3 else: 1)
  if last <= first: "" else: source[first ..< last]

proc joinsWithConstant(gap: string): bool =
  ## `" & someConst & "` is a single string expression: the constant is part of
  ## the same value. Only that exact shape folds, so two unrelated statements
  ## can never merge into one another.
  let text = gap.strip()
  if text.len < 3 or text[0] != '&' or text[^1] != '&':
    return false
  let name = text[1 ..< text.len - 1].strip()
  if name.len == 0 or name[0] notin {'A'..'Z', 'a'..'z', '_'}:
    return false
  for ch in name:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '.'}:
      return false
  true

proc stringLiterals*(source: string): seq[string] =
  ## Contents of every "..." and """...""" literal. Literals joined by
  ## `" & someConst & "` are one string, so they are merged: a SQL statement
  ## whose SET clause comes from a shared constant must be judged as that
  ## statement, not as a fragment that appears to lack its community scope.
  var index = 0
  var previousEnd = -1
  while index < source.len:
    if source[index] != '"':
      inc index
      continue
    let finish = literalEnd(source, index)
    let body = literalBody(source, index, finish)
    if previousEnd >= 0 and joinsWithConstant(source[previousEnd ..< index]):
      result[^1].add(body)
    else:
      result.add(body)
    previousEnd = finish
    index = finish

proc normalize(path: string): string =
  path.replace('\\', '/')

proc importLines(source: string): seq[(int, string)] =
  let lines = stripStrings(source.splitLines())
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
      elif not file.contains("/tests/") and
           (line.contains("api/") or line.contains("routes_gen")):
        # `config.nims` puts `apps` on the path, so `import api/src/routes_gen`
        # reaches the delivery layer without the `apps/` prefix. Tests may read
        # the route table (the authz matrix does); product code may not.
        result.add(file & ":" & $lineNumber &
          ": modules must not import the delivery layer (api/)")
      if file.contains("/domain/") and
         (line.contains("db/db") or line.contains("db_connector")):
        result.add(file & ":" & $lineNumber &
          ": domain must not import the database layer")
  let codeLines = stripStrings(source.splitLines())
  for index in 0 ..< codeLines.len:
    let trimmed = codeLines[index].strip()
    if trimmed.startsWith("#"):
      continue
    if (trimmed.contains("now()") or trimmed.contains("times.now(")) and
       file != "shared/platform-lib/clock.nim" and
       not file.contains("/tests/") and not trimmed.contains("default now()"):
      result.add(file & ":" & $(index + 1) & ": use clock.utcNow(), not now()")
    if trimmed.contains("epochTime(") and
       file != "shared/platform-lib/clock.nim" and
       not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": use clock.utcNow(), not epochTime()")
    if trimmed.contains("getEnv(") and not envAllowed(file) and
       not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": environment access is only allowed at the process edge")

  # Community scope is checked on SQL string literals only. Prose in comments
  # mentions the tables too, and must not be reported.
  if file.startsWith("modules/") and not file.contains("/tests/"):
    for literal in stringLiterals(source):
      let statement = literal.strip().toLowerAscii()
      if not (statement.startsWith("select") or statement.startsWith("insert") or
              statement.startsWith("update") or statement.startsWith("delete") or
              statement.startsWith("with")):
        continue
      for table in domainTables:
        if literal.contains(table) and not literal.contains("community_id"):
          result.add(file & ": SQL touches " & table &
            " without community_id in the same statement")
