import std/[strutils]

const
  domainTables = ["session.", "player.", "rating.", "tournament.", "community."]
  envAllowlist = ["shared/platform-lib/clock.nim"]

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

proc stringLiterals*(source: string): seq[string] =
  ## Contents of every "..." and """...""" literal, concatenated per literal.
  var current = ""
  var collected = false
  var index = 0
  while index < source.len:
    if index + 2 < source.len and source[index] == '"' and
       source[index + 1] == '"' and source[index + 2] == '"':
      index += 3
      while index < source.len:
        if index + 2 < source.len and source[index] == '"' and
           source[index + 1] == '"' and source[index + 2] == '"':
          index += 3
          break
        current.add(source[index])
        index.inc
      result.add(current)
      current = ""
      collected = false
    elif source[index] == '"':
      index.inc
      current = ""
      while index < source.len and source[index] != '"':
        if source[index] == '\\' and index + 1 < source.len:
          index.inc
        current.add(source[index])
        index.inc
      index.inc
      result.add(current)
      current = ""
    else:
      index.inc

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
    if trimmed.contains("getEnv(") and not envAllowed(file) and
       not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": environment access is only allowed at the process edge")

  # Community scope is checked on SQL string literals only. Prose in comments
  # mentions the tables too, and must not be reported.
  if file.startsWith("modules/"):
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
