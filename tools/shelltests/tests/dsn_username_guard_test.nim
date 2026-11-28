# SEC-DB-06: a connection string passed into a username slot.
#
# On 2026-11-26 04:58:45 UTC the postgres journal recorded
# `FATAL role "postgres://bm2_owner:<password>@qouver-po..."`: a full live DSN
# arrived where a bare role belongs, and the server truncated it at 63 chars.
# The journal proves it happened once; this guard makes the shape unrepresentable
# in the scripts the repository ships, whatever hand-run command produced the
# original line.
#
# A username slot is `-U`, `--username`, `PGUSER=` or a `user=` field in a
# conninfo string. A value in one is a violation when it is
#   - a literal containing "://",
#   - a variable this file fills from a connection string, through any number of
#     assignments: a literal "://", an alias of a dsn-named variable, a value
#     read out of an env file by a dsn-named key, or a reassignment after a
#     benign value (`ROLE=postgres` then `ROLE="${MAJADU_PG_DSN}"`), or
#   - a variable whose name says it holds a connection string (`*_DSN`,
#     `*_URL`, `*_URI`, `*_CONN`, `*PGURL`) and that this file cannot resolve,
#     because the name is the only evidence available and it is enough.
# A variable the file cannot resolve and whose name says nothing, such as
# `PGUSER="$MAJADU_PG_SUPERUSER"`, is printed as a candidate instead of failing:
# a guard that fails on every variable would be turned off the first week.
#
# The scan reads ops/, tools/ and task.d/ (shell scripts by extension or shebang)
# and the systemd unit and env templates, because a passing command can be written
# down in any of them. Candidates are always printed, so the ambiguous lines stay
# visible without failing a branch.

import std/[algorithm, os, strutils, tables, unittest]
import ../harness

type
  Severity = enum
    sevViolation, sevCandidate

  Finding = object
    where: string
    severity: Severity
    reason: string

  Scan = object
    findings: seq[Finding]
    slots: int

const
  scanRoots = ["ops", "tools", "task.d"]
  # `.example` covers the env templates the units load as EnvironmentFile: a
  # `PGUSER=` written there is passed by the unit, not by a script.
  shellExts = [".sh", ".bash", ".service", ".container", ".timer", ".example"]
  dsnComponents = ["DSN", "URL", "URI", "CONN", "CONNINFO", "PGURL", "PGDSN"]

proc isIdent(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc isDsnishName(name: string): bool =
  ## The name says the value is a connection string, not a bare role. Compared
  ## as whole `_`-separated components, so `CURL_LOG` is not a `URL`.
  let upper = name.toUpperAscii
  if upper.endsWith("DSN"):
    return true
  for part in upper.split('_'):
    for component in dsnComponents:
      if part == component:
        return true
  false

proc refsIn(value: string): seq[string] =
  ## Every `$NAME` and `${NAME}` in a value. `${A:-x}` yields `A`.
  var i = 0
  while i < value.len:
    if value[i] != '$':
      inc i
      continue
    var j = i + 1
    if j < value.len and value[j] == '{':
      inc j
    let start = j
    while j < value.len and isIdent(value[j]):
      inc j
    if j > start:
      result.add value[start ..< j]
      i = j
    else:
      inc i

proc assignment(line: string): tuple[name, value: string] =
  ## The first `NAME=value` on a line, wherever it sits: bare, after `export`,
  ## or inside `-e "PGUSER=..."`.
  var i = 0
  while i < line.len:
    if isIdent(line[i]) and line[i] notin {'0' .. '9'} and
        (i == 0 or not isIdent(line[i - 1])):
      var j = i
      while j < line.len and isIdent(line[j]):
        inc j
      if j < line.len and line[j] == '=':
        return (line[i ..< j], line[j + 1 .. ^1])
      i = j
      continue
    inc i

proc stripComment(line: string): string =
  ## Drops a trailing `# ...` that starts a word outside quotes. A `#` inside a
  ## quoted string is part of the value, and `psql "$DSN"  # -U takes the role`
  ## is a sentence about the code, not a call.
  var quote = '\0'
  var i = 0
  while i < line.len:
    let c = line[i]
    if quote != '\0':
      if c == '\\' and quote == '"':
        inc i
      elif c == quote:
        quote = '\0'
    elif c in {'"', '\''}:
      quote = c
    elif c == '#' and (i == 0 or line[i - 1] in {' ', '\t'}):
      return line[0 ..< i]
    inc i
  line

proc taintTable(lines: seq[string]): Table[string, bool] =
  ## Variable names that hold a connection string. Three sources, all of them
  ## retained instead of the first assignment only: a reassignment after a benign
  ## value is exactly how a role starts life clean and then carries a DSN
  ## (`ROLE=postgres` then `ROLE="${MAJADU_PG_DSN}"`). Also tainted: a value read
  ## out of an env file by a dsn-named key
  ## (`sed -n 's/^MAJADU_OWNER_DSN=//p' env/majadu-tools.env`), and a ref whose
  ## own name says it is a connection string, which is how `OWNER="${MAJADU_PG_DSN}"`
  ## carries one through an alias.
  var rhs: seq[tuple[name, value: string]]
  for line in lines:
    if line.strip.startsWith("#"):
      continue
    let (name, value) = assignment(line)
    if name.len > 0:
      rhs.add (name, value)
  for _ in 0 ..< 3:
    for (name, value) in rhs:
      if result.getOrDefault(name):
        continue
      if value.contains("://"):
        result[name] = true
        continue
      # A value read out of an env file by a dsn-named key, as the rehearsal
      # harness reads the owner DSN before handing it on:
      #   READ_OWNER="$(sed -n 's/^MAJADU_OWNER_DSN=//p' tools.env)"
      if value.contains(".env") or value.contains("$("):
        var word = ""
        var named = false
        for c in value & " ":
          if isIdent(c):
            word.add c
            continue
          if word.len > 0 and isDsnishName(word):
            named = true
          word = ""
        if named:
          result[name] = true
          continue
      for refName in refsIn(value):
        if result.getOrDefault(refName) or isDsnishName(refName):
          result[name] = true
          break

proc judge(value: string, taint: Table[string, bool]): tuple[flagged: bool,
    severity: Severity, reason: string] =
  ## What one value handed to a username slot proves. Quoting decides how the
  ## shell splits the word, never whether the value is a DSN.
  let token = value.strip(chars = {'"', '\''})
  if token.len == 0:
    return
  if token.contains("://"):
    # The value is not echoed: the reason lands in a CI log, and the value a
    # guard like this catches is exactly the one that must not be copied there.
    return (true, sevViolation,
      "a literal connection string containing '://'")
  let refs = refsIn(token)
  if refs.len == 0 and not token.contains("$("):
    return                       # a bare role name, which is what belongs here
  for name in refs:
    if taint.getOrDefault(name) or isDsnishName(name):
      return (true, sevViolation, "$" & name & " holds a connection string")
  let how = if token.contains("$("): "a command substitution"
            elif refs.len > 0: "$" & refs[0]
            else: "no variable"
  (true, sevCandidate, how & " is not resolved by this file")

proc tokenAt(line: string, start: int): string =
  ## The shell word that begins at `start`. A quoted word keeps its spaces; an
  ## unquoted one ends at the first blank or operator.
  var i = start
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if i < line.len and line[i] in {'"', '\''}:
    let quote = line[i]
    inc i
    while i < line.len:
      if line[i] == '\\' and quote == '"' and i + 1 < line.len:
        result.add line[i]
        result.add line[i + 1]
        i += 2
        continue
      if line[i] == quote:
        break
      result.add line[i]
      inc i
  else:
    while i < line.len and line[i] notin {' ', '\t', ';', '|', '&', ')', '}',
        '"', '\''}:
      result.add line[i]
      inc i

proc slotsIn(line: string): seq[string] =
  ## Every value this line hands to a username slot.
  var i = 0
  while i < line.len:
    if line.continuesWith("-U", i) and (i == 0 or not isIdent(line[i - 1])):
      result.add tokenAt(line, i + 2)
      i += 2
      continue
    if line.continuesWith("--username", i) and
        (i == 0 or not isIdent(line[i - 1])):
      let after = i + "--username".len
      if after >= line.len or line[after] in {' ', '\t', '=', '"', '\''}:
        result.add tokenAt(line, if after < line.len and line[after] == '=':
          after + 1 else: after)
        i = after + 1
        continue
    if line.continuesWith("PGUSER", i) and (i == 0 or not isIdent(line[i - 1])):
      let after = i + "PGUSER".len
      if after < line.len and line[after] == '=':
        result.add tokenAt(line, after + 1)
        i = after + 1
        continue
    if line.continuesWith("user=", i) and
        (i == 0 or (line[i - 1] notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9',
          '_', '-', '/'})):
      result.add tokenAt(line, i + "user=".len)
      i += "user=".len
      continue
    inc i

proc joinContinuations(lines: seq[string]): seq[(int, string)] =
  ## `psql -U \` then the role on the next line is one command; a guard that
  ## reads the lines separately sees an empty slot and skips the DSN on the next
  ## line. The line number reported is where the call starts.
  var i = 0
  while i < lines.len:
    var text = lines[i]
    let start = i
    while text.endsWith("\\") and i + 1 < lines.len:
      text = text[0 ..< ^1] & " " & lines[i + 1]
      inc i
    result.add (start, text)
    inc i

proc scanFile(path: string): Scan =
  var lines: seq[string]
  try:
    lines = readFile(path).splitLines
  except IOError:
    return
  let taint = taintTable(lines)
  for (start, raw) in joinContinuations(lines):
    let line = stripComment(raw).strip
    if line.len == 0:
      continue
    for value in slotsIn(line):
      inc result.slots
      let verdict = judge(value, taint)
      if verdict.flagged:
        result.findings.add Finding(where: path & ":" & $(start + 1),
          severity: verdict.severity, reason: verdict.reason)

proc hasShellShebang(path: string): bool =
  var head: array[64, char]
  var file: File
  if not open(file, path):
    return false
  let n = file.readBuffer(addr head[0], head.len)
  file.close()
  if n <= 0:
    return false
  var text = ""
  for i in 0 ..< n:
    text.add head[i]
  text.startsWith("#!") and text.contains("sh")

proc isScanned(path: string): bool =
  let ext = splitFile(path).ext
  if ext in shellExts:
    return true
  # `task.d/*` are extensionless and start with `#!/bin/sh`; a compiled suite
  # sits in the same tree and has no shebang, so the bytes decide.
  if ext.len == 0:
    return hasShellShebang(path)
  false

proc shellFiles(root: string): seq[string] =
  for sub in scanRoots:
    let dir = root / sub
    if not dirExists(dir):
      continue
    for path in walkDirRec(dir):
      if isScanned(path):
        result.add path
  let runner = root / "task"
  if fileExists(runner):
    result.add runner
  result.sort

proc render(findings: seq[Finding]): seq[string] =
  for f in findings:
    let label = if f.severity == sevViolation: "VIOLATION" else: "candidate"
    result.add f.where & ": " & label & ": " & f.reason

proc scanTree(root: string): Scan =
  for path in shellFiles(root):
    let one = scanFile(path)
    result.slots += one.slots
    for f in one.findings:
      result.findings.add Finding(where: f.where, severity: f.severity,
        reason: f.reason)

proc writeScript(fixture: Fixture, relative, body: string): string =
  let path = fixture.root / relative
  createDir(path.parentDir)
  writeFile(path, body)
  path

suite "DSN in a username slot":
  test "no shipping script passes a connection string where a role belongs":
    let scan = scanTree(repoDir)
    # A scan that read nothing passes for the wrong reason, so both counts are
    # part of the verdict.
    check shellFiles(repoDir).len > 50
    check scan.slots > 0
    var violations, candidates: seq[Finding]
    for f in scan.findings:
      if f.severity == sevViolation:
        violations.add f
      else:
        candidates.add f
    echo "dsn-guard: ", shellFiles(repoDir).len, " file(s), ", scan.slots,
      " username slot(s), ", violations.len, " violation(s), ",
      candidates.len, " candidate(s)"
    for line in render(candidates):
      echo "dsn-guard: ", line
    for line in render(violations):
      echo "dsn-guard: ", line
    check violations.len == 0

  test "a literal DSN in -U is a violation":
    let fixture = newFixture("dsn-literal-U")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql -U \"postgresql://bm2_owner:secret@127.0.0.1:5432/bm2\" " &
      "-c 'select 1'\n")
    let scan = scanTree(fixture.root)
    let lines = render(scan.findings)
    check scan.findings.len == 1
    check lines.len == 1 and lines[0].contains("VIOLATION")
    check lines[0].contains("proof.sh:2")

  test "a DSN reached through a second variable is a violation":
    let fixture = newFixture("dsn-indirect-U")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\nREAD_OWNER=\"$(sed -n 's/^MAJADU_OWNER_DSN=//p' tools.env)\"\n" &
      "OWNER=\"$READ_OWNER\"\npsql -U \"$OWNER\" -c 'select 1'\n")
    let scan = scanTree(fixture.root)
    check scan.findings.len == 1
    check render(scan.findings)[0].contains("OWNER holds a connection string")

  test "an alias of a DSN-named variable is a violation, not a candidate":
    ## A plain alias is the shortest way to launder a DSN into a role slot: the
    ## value never shows "://" and the local name says nothing. `judge` already
    ## treats a DSN-named ref as a violation, but `taintTable` has to taint the
    ## alias first or the local variable is only a candidate.
    let fixture = newFixture("dsn-alias")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\nOWNER=\"${MAJADU_PG_DSN}\"\npsql -U \"$OWNER\" -c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("$OWNER holds a connection string")

  test "a reassignment after a benign value is a violation":
    ## `ROLE=postgres` then `ROLE="${MAJADU_PG_DSN}"` is the same leak with a
    ## greeting in front. Keeping only the first assignment per name made the
    ## poisoned second one invisible.
    let fixture = newFixture("dsn-reassign")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\nROLE=postgres\nROLE=\"${MAJADU_PG_DSN}\"\n" &
      "psql -U \"$ROLE\" -c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("$ROLE holds a connection string")

  test "an unresolved DSN-named variable is a violation":
    let fixture = newFixture("dsn-env-U")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql -U \"$MAJADU_OWNER_DSN\" -c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("MAJADU_OWNER_DSN holds a connection string")

  test "a conninfo user= built from a DSN is a violation":
    let fixture = newFixture("dsn-conninfo")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql \"host=127.0.0.1 user=$MAJADU_OWNER_DSN\" " &
      "-c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("MAJADU_OWNER_DSN")

  test "a literal DSN in PGUSER is a violation":
    let fixture = newFixture("dsn-pguser")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\nPGUSER=postgresql://bm2_owner:secret@127.0.0.1:5432/bm2 " &
      "psql -c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("literal connection string")
    # The guard reports the shape, never the value: a CI log is public too.
    check not lines[0].contains("secret")

  test "a unit template is scanned too":
    let fixture = newFixture("dsn-unit")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/systemd/proof.service",
      "[Service]\nEnvironment=PGUSER=postgresql://bm2_owner:secret@db/bm2\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("proof.service:2")

  test "a bare role in every slot is clean":
    let fixture = newFixture("dsn-bare-role")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql -U postgres -c 'select 1'\n" &
      "PGUSER=postgres psql -c 'select 1'\n" &
      "psql \"host=127.0.0.1 user=postgres\" -c 'select 1'\n" &
      "psql --username=postgres -c 'select 1'\n")
    let scan = scanTree(fixture.root)
    check scan.slots == 4
    check scan.findings.len == 0

  test "a comment that names a slot is not a call":
    let fixture = newFixture("dsn-comment")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\n# psql -U postgres is the only way to override the role\n" &
      "psql -d \"$MAJADU_OWNER_DSN\" # -U would take a role here\n")
    let scan = scanTree(fixture.root)
    check scan.slots == 0
    check scan.findings.len == 0

  test "a slot split across a line continuation is still read":
    let fixture = newFixture("dsn-continuation")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql \\\n  -U \"$MAJADU_OWNER_DSN\" \\\n  -c 'select 1'\n")
    let lines = render(scanTree(fixture.root).findings)
    check lines.len == 1
    check lines[0].contains("VIOLATION")
    check lines[0].contains("proof.sh:2")

  test "an unresolved role variable is a candidate, not a failure":
    let fixture = newFixture("dsn-candidate")
    defer: removeDir(fixture.root)
    discard writeScript(fixture, "ops/scripts/proof.sh",
      "#!/bin/sh\npsql -U \"$MAJADU_PG_SUPERUSER\" -c 'select 1'\n")
    let scan = scanTree(fixture.root)
    check scan.findings.len == 1
    check scan.findings[0].severity == sevCandidate
