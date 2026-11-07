import std/[strutils]

## T-098: a business number has one home, `platform.config`, and the seed file
## is what the database actually holds. A literal in code that repeats a seeded
## default is a second home, and the two drift the day someone changes the row.
##
## The scan is deliberately narrow: only values at or above `minBusinessValue`
## are treated as business numbers. Page sizes, limits, windows and durations
## live there; loop indices and small enum-like numbers do not, and flagging
## them would drown the real findings.

const
  minBusinessValue* = 50
  seedPath* = "db/seeds/platform_config.sql"
  registryPath* = "modules/platform/config/registry.nim"

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

  SeedRow* = object
    ## One row of the config seed. `hasBounds` is false when the row stores
    ## `null` in `min_value`/`max_value`; `partialBounds` marks a row where only
    ## one of the two is null, which is drift no comparison can express.
    key*: string
    kind*: string
    value*: int
    hasValue*: bool
    hasBounds*: bool
    partialBounds*: bool
    minValue*: float
    maxValue*: float

  RegistrySpec* = object
    ## One `spec(...)` entry from `modules/platform/config/registry.nim`.
    key*: string
    kind*: string
    hasBounds*: bool
    minValue*: float
    maxValue*: float

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

proc numeric(text: string, value: var float): bool =
  ## `10_000` is a Nim literal; bounds are compared as numbers, not text.
  var cleaned = ""
  for c in text:
    if c != '_':
      cleaned.add(c)
  try:
    value = parseFloat(cleaned)
    result = true
  except ValueError:
    result = false

proc seedRows*(seedSql: string): seq[SeedRow] =
  ## Reads `('key', 'kind', 'value', min, max, ...)` tuples including the bound
  ## columns the value scan ignores. Tuples are read from the whole file, not
  ## line by line, because a `json` value spans several lines.
  var index = 0
  while index < seedSql.len:
    let start = seedSql.find("('", index)
    if start < 0:
      break
    let keyStart = start + 2
    let keyEnd = seedSql.find('\'', keyStart)
    if keyEnd < 0:
      break
    let kindStart = seedSql.find('\'', keyEnd + 1)
    if kindStart < 0:
      break
    let kindEnd = seedSql.find('\'', kindStart + 1)
    if kindEnd < 0:
      break
    let valueStart = seedSql.find('\'', kindEnd + 1)
    if valueStart < 0:
      break
    let valueEnd = seedSql.find('\'', valueStart + 1)
    if valueEnd < 0:
      break
    let boundsEnd = seedSql.find('\'', valueEnd + 1)
    if boundsEnd < 0:
      break
    var row = SeedRow(key: seedSql[keyStart ..< keyEnd],
      kind: seedSql[kindStart + 1 ..< kindEnd])
    var cleaned = ""
    for c in seedSql[valueStart + 1 ..< valueEnd]:
      if c != '_':
        cleaned.add(c)
    try:
      row.value = parseInt(cleaned.split('.')[0])
      row.hasValue = true
    except ValueError:
      row.hasValue = false
    var bounds: seq[float] = @[]
    var nullBounds = false
    for item in seedSql[valueEnd + 1 ..< boundsEnd].split(','):
      let text = item.strip()
      if text.len == 0:
        continue
      var value: float
      if text == "null":
        nullBounds = true
      elif numeric(text, value):
        bounds.add(value)
      else:
        nullBounds = true
    if not nullBounds and bounds.len == 2:
      row.hasBounds = true
      row.minValue = bounds[0]
      row.maxValue = bounds[1]
    row.partialBounds = nullBounds and bounds.len > 0
    result.add(row)
    index = boundsEnd

proc seededValues*(seedSql: string, minimum = minBusinessValue): seq[SeededValue] =
  ## Reads `('key', 'int'|'decimal', 'value', ...)` rows out of the config seed.
  ## It runs on `seedRows`, so a reformat that puts several tuples on one line
  ## cannot hide a value from the duplication scan.
  var seen: seq[int] = @[]
  for row in seedRows(seedSql):
    if row.kind != "int" and row.kind != "decimal":
      continue
    if not row.hasValue:
      continue
    let value = row.value
    if value < minimum or isProtocolNumber(value) or value in seen:
      continue
    seen.add(value)
    result.add(SeededValue(key: row.key, value: value))

proc configKind(enumName: string): string =
  case enumName
  of "ctInt": "int"
  of "ctDecimal": "decimal"
  of "ctBool": "bool"
  of "ctString": "string"
  of "ctJson": "json"
  else: ""

proc callArguments(source: string, name: string): seq[seq[string]] =
  ## Top-level, comma-separated arguments of every `name(...)` call. The calls
  ## in the registry span several lines, so the whole source is read at once.
  var index = 0
  while index < source.len:
    let start = source.find(name & "(", index)
    if start < 0:
      break
    var position = start + name.len + 1
    var depth = 1
    var body = ""
    while position < source.len and depth > 0:
      let c = source[position]
      if c == '(':
        depth.inc
      elif c == ')':
        depth.dec
      if depth > 0:
        body.add(c)
      position.inc
    var args: seq[string] = @[]
    var current = ""
    var nested = 0
    for c in body:
      case c
      of '(':
        nested.inc
        current.add(c)
      of ')':
        nested.dec
        current.add(c)
      of ',':
        if nested == 0:
          args.add(current.strip())
          current = ""
        else:
          current.add(c)
      else:
        current.add(c)
    if current.strip().len > 0:
      args.add(current.strip())
    result.add(args)
    index = position

proc registrySpecs*(registrySource: string): seq[RegistrySpec] =
  ## Every `spec(keyFoo, ctInt, min, max, true, ...)` in the registry, mapped
  ## back to its database key. The `proc spec` definition has no database key
  ## and is skipped by that lookup.
  var keys: seq[(string, string)] = @[]
  for raw in registrySource.splitLines():
    let line = raw.strip()
    if not line.startsWith("key"):
      continue
    let equals = line.find(" = \"")
    if equals < 0:
      continue
    let firstQuote = equals + 4
    let lastQuote = line.find('"', firstQuote)
    if lastQuote < 0:
      continue
    keys.add((line[0 ..< equals], line[firstQuote ..< lastQuote]))
  for args in callArguments(registrySource, "spec"):
    if args.len < 2:
      continue
    var key = ""
    for (enumName, dbKey) in keys:
      if enumName == args[0]:
        key = dbKey
        break
    if key.len == 0:
      continue
    var spec = RegistrySpec(key: key, kind: configKind(args[1]))
    if args.len >= 5 and args[4] == "true":
      var low, high: float
      if numeric(args[2], low) and numeric(args[3], high):
        spec.hasBounds = true
        spec.minValue = low
        spec.maxValue = high
    result.add(spec)

proc renderBound(value: float): string =
  let whole = int(value)
  if float(whole) == value: $whole else: $value

proc boundViolations*(specs: seq[RegistrySpec],
                      rows: seq[SeedRow]): seq[string] =
  ## The registry is where a bound is decided and the seed repeats it for the
  ## database. A bound present in only one of them is drift the value scan
  ## cannot see, and X-4's clamp will trust whichever it reads.
  for spec in specs:
    var row: SeedRow
    var found = false
    for candidate in rows:
      if candidate.key == spec.key:
        row = candidate
        found = true
        break
    if not found:
      result.add(registryPath & ": " & spec.key & " has no row in " & seedPath)
      continue
    if row.partialBounds:
      result.add(seedPath & ": " & spec.key &
        " stores only one of min_value/max_value")
      continue
    if spec.hasBounds and not row.hasBounds:
      result.add(registryPath & ": " & spec.key & " declares min " &
        renderBound(spec.minValue) & " max " & renderBound(spec.maxValue) &
        " but " & seedPath & " stores null bounds")
    elif not spec.hasBounds and row.hasBounds:
      result.add(registryPath & ": " & spec.key & " declares no bounds but " &
        seedPath & " stores min " & renderBound(row.minValue) & " max " &
        renderBound(row.maxValue))
    elif spec.hasBounds:
      if spec.minValue != row.minValue:
        result.add(registryPath & ": " & spec.key & " min " &
          renderBound(spec.minValue) & " does not match " & seedPath & " (" &
          renderBound(row.minValue) & ")")
      if spec.maxValue != row.maxValue:
        result.add(registryPath & ": " & spec.key & " max " &
          renderBound(spec.maxValue) & " does not match " & seedPath & " (" &
          renderBound(row.maxValue) & ")")
  # A seed row nobody declared is dead weight at best and a typo at worst; the
  # app reads the registry, so the row would never take effect.
  for row in rows:
    var known = false
    for spec in specs:
      if spec.key == row.key:
        known = true
        break
    if not known:
      result.add(seedPath & ": " & row.key & " is not declared in " &
        registryPath)

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
