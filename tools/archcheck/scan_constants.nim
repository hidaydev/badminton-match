import std/[strutils]

## T-098: a business number has one home, `platform.config`, and the seed file
## is what the database actually holds. A literal in code that repeats a seeded
## default is a second home, and the two drift the day someone changes the row.
##
## The scan is deliberately narrow: only values at or above `minBusinessValue`
## are treated as business numbers. Page sizes, limits, windows and durations
## live there; loop indices and small enum-like numbers do not, and flagging
## them would drown the real findings.

const minBusinessValue* = 50

## Protocol numbers are not business numbers. A 503 from a probe is not an
## attempt to configure readiness. Limitation, stated on purpose: a business
## default that is also a status code (100, 200) is invisible to this scan,
## because every handler answers with those numbers.
const protocolNumbers = [
  100, 101, 200, 201, 202, 204, 206, 300, 301, 302, 304, 307, 308, 400, 401,
  403, 404, 405, 408, 409, 410, 412, 413, 414, 415, 422, 429, 500, 501, 502,
  503, 504]

type
  SeededValue* = object
    key*: string
    value*: int

proc isProtocolNumber(value: int): bool =
  value in protocolNumbers

proc stripCommentsAndStrings(line: string): string =
  ## Removes `"..."` contents and stops at `#`, so a SQL default or a log
  ## message cannot look like a code literal.
  var inString = false
  var escaped = false
  for c in line:
    if inString:
      if escaped:
        escaped = false
      elif c == '\\':
        escaped = true
      elif c == '"':
        inString = false
      continue
    if c == '"':
      inString = true
      continue
    if c == '#':
      break
    result.add(c)

proc seededValues*(seedSql: string, minimum = minBusinessValue): seq[SeededValue] =
  ## Reads `('key', 'int'|'decimal', 'value', ...)` rows out of the config seed.
  var seen: seq[int] = @[]
  for raw in seedSql.splitLines():
    let line = raw.strip()
    if not line.startsWith("('"):
      continue
    let parts = line.split("'")
    if parts.len < 6:
      continue
    let kind = parts[3]
    if kind != "int" and kind != "decimal":
      continue
    var value: int
    try:
      value = parseInt(parts[5].split('.')[0])
    except ValueError:
      continue
    if value < minimum or isProtocolNumber(value) or value in seen:
      continue
    seen.add(value)
    result.add(SeededValue(key: parts[1], value: value))

proc numberKey(path: string, value: int): string =
  path.replace('\\', '/') & ":" & $value

proc loadAllowlist*(text: string): seq[string] =
  ## One `path:value` per line; anything after `#` is the reason it is exempt.
  for raw in text.splitLines():
    let line = raw.split('#')[0].strip()
    if line.len > 0:
      result.add(line)

proc report(file, digits: string, lineNumber: int, values: seq[SeededValue],
            allowed: openArray[string], found: var seq[string]) =
  var match = -1
  for position in 0 ..< values.len:
    if $values[position].value == digits:
      match = position
      break
  if match < 0:
    return
  # A bare path exempts the whole file; `path:value` exempts one literal.
  if file in allowed or numberKey(file, values[match].value) in allowed:
    return
  found.add(file & ":" & $lineNumber & ": " & digits & " duplicates " &
    values[match].key & " (read it from the config snapshot)")

proc constantViolations*(path, source: string, values: seq[SeededValue],
                         allowed: openArray[string] = []): seq[string] =
  let file = path.replace('\\', '/')
  let lines = source.splitLines()
  for lineNumber in 0 ..< lines.len:
    let line = stripCommentsAndStrings(lines[lineNumber])
    var digits = ""
    var start = 0
    var position = 0
    while position <= line.len:
      let c = if position < line.len: line[position] else: ' '
      if c in {'0'..'9'}:
        if digits.len == 0:
          start = position
        digits.add(c)
        position.inc
        continue
      if digits.len > 0:
        let before = if start > 0: line[start - 1] else: ' '
        let after = c
        # A number glued to an identifier is part of a name, not a literal.
        if before notin {'a'..'z', 'A'..'Z', '_', '.'} and
           after notin {'a'..'z', 'A'..'Z', '_'}:
          report(file, digits, lineNumber + 1, values, allowed, result)
        digits = ""
      position.inc
