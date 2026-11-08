import std/[os, osproc, strtabs, strutils, unittest]

import ../main

# `parseArgs` reads the process command line, so its refusal cases are driven by
# re-executing this binary with the flag under test. The probe travels in the
# environment because the argument list is exactly what the parser consumes.
const probeVariable = "FIXTURES_TEST_PROBE"

proc probeEnv(value: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[probeVariable] = value

proc diagnostics(output: string): string =
  ## The lines the program itself wrote. `execCmdEx` merges stderr into its
  ## output, and an instrumented build (`.`/task coverage`) has the profiling
  ## runtime writing `profiling:` warnings there, so those are dropped before
  ## the contract this suite asserts is read.
  for line in output.splitLines():
    if line.startsWith("profiling:"):
      continue
    if result.len > 0:
      result.add "\n"
    result.add line

proc selfRun(args: seq[string]): tuple[output: string, exitCode: int] =
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  execCmdEx(command, env = probeEnv("args"))

when isMainModule:
  if getEnv(probeVariable) == "args":
    discard parseArgs()
    quit(0)

# `uuidFor` is keyed by a namespace, and namespace 1 is `nsPlayer`.
const playerNamespace = 1

proc committedFixturePath(): string =
  ## The golden lives at a fixed path in the tree. `currentSourcePath` keeps the
  ## lookup working when the suite is compiled with an absolute path; the second
  ## candidate covers a run from a different working directory.
  const fromSource = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  result = fromSource / "ops/dev/v1/fixtures/v1-fixtures.sql"
  if not fileExists(result):
    result = getCurrentDir() / "ops/dev/v1/fixtures/v1-fixtures.sql"

suite "buildSql determinism":
  test "the same seed produces byte-identical SQL twice in one process":
    let first = buildSql(7)
    let second = buildSql(7)
    check first.len > 30000
    check first == second

  test "the seed header line and the player ids follow the seed":
    let seven = buildSql(7)
    let eight = buildSql(8)
    check seven.contains("-- seed: 7, players: 12\n")
    check eight.contains("-- seed: 8, players: 12\n")
    check seven != eight
    let idSeven = uuidFor(7, playerNamespace, 0)
    let idEight = uuidFor(8, playerNamespace, 0)
    check seven.contains("'" & idSeven & "'")
    check eight.contains("'" & idEight & "'")
    check not seven.contains("'" & idEight & "'")

  test "every v1 table is either truncated or written":
    let sql = buildSql(7)
    check sql.contains("truncate table\n  bm.outbox_events")
    check sql.contains("insert into bm.players")
    check sql.contains("insert into bm.scheduled_games")
    check sql.startsWith("-- Synthetic v1 fixture")
    check sql.endsWith("commit;\n")

suite "uuidFor":
  test "the same triple always produces the same identifier":
    check uuidFor(7, playerNamespace, 0) == uuidFor(7, playerNamespace, 0)

  test "any component of the triple changes the identifier":
    let base = uuidFor(7, playerNamespace, 0)
    check base != uuidFor(8, playerNamespace, 0)
    check base != uuidFor(7, playerNamespace + 1, 0)
    check base != uuidFor(7, playerNamespace, 1)

  test "the text is a lowercase UUIDv4 shape":
    let value = uuidFor(7, playerNamespace, 3)
    check value.len == 36
    check value[8] == '-' and value[13] == '-' and value[18] == '-' and
      value[23] == '-'
    check value[14] == '4'
    check value[19] in {'8', '9', 'a', 'b'}
    check value == value.toLowerAscii
    for index, character in value:
      if index in [8, 13, 18, 23]:
        continue
      check character in {'0'..'9', 'a'..'f'}

suite "outputFile":
  test "a .sql path is returned unchanged":
    check outputFile("x.sql") == "x.sql"

  test "the extension check is case-insensitive":
    check outputFile("A.SQL") == "A.SQL"

  test "a directory gains the default file name":
    check outputFile("dir") == "dir" / "v1-fixtures.sql"

suite "parseArgs":
  test "a negative seed is refused":
    let run = selfRun(@["--seed", "-1"])
    check run.exitCode == 1
    check diagnostics(run.output).contains("--seed must not be negative")

  test "a non-numeric seed is refused":
    let run = selfRun(@["--seed", "nope"])
    check run.exitCode == 1
    check diagnostics(run.output).contains("--seed is not a number: nope")

  test "a numeric seed is accepted":
    let run = selfRun(@["--seed", "11"])
    check run.exitCode == 0
    check diagnostics(run.output).len == 0

proc firstDifference(left, right: string): int =
  ## Byte offset of the first difference, or the common length when one string
  ## is a prefix of the other.
  while result < left.len and result < right.len and
      left[result] == right[result]:
    inc result

proc excerpt(value: string; at: int): string =
  if at >= value.len:
    return "<end of file>"
  value[at ..< min(value.len, at + 60)]

proc withoutBadgeRows(sql: string): string =
  ## The committed fixture carries the v1 badge shape (`medal:<unit>` rows with
  ## the current statistic, plus one `tournament:<id>` event badge) because the
  ## import suite reads it, and that block was hand-tuned in 2c41686a: the
  ## values are chosen per player, not derived from the seed. The generator
  ## still emits the older `rank-10` style rows, so the two agree on every other
  ## statement. D-16 tracks teaching the generator the medal shape; until then
  ## the comparison below excludes exactly this block, and the next case pins
  ## the shape the ETL depends on so the exclusion cannot hide a regression.
  ##
  ## Strip the explanatory comment above the insert and the insert itself.
  var skippingComment = false
  var skippingInsert = false
  for line in sql.splitLines():
    if skippingInsert:
      if line == ");":
        skippingInsert = false
      continue
    if skippingComment:
      if not line.startsWith("--"):
        skippingComment = false
      else:
        continue
    if line.startsWith("-- v1 stores one row per ladder"):
      skippingComment = true
      continue
    if line.startsWith("insert into bm.player_achievements"):
      skippingInsert = true
      continue
    result.add line
    result.add "\n"

suite "committed fixture":
  test "buildSql(7) matches the committed v1 fixture outside the badge block":
    let path = committedFixturePath()
    check path.fileExists
    let committed = withoutBadgeRows(readFile(path))
    let fresh = withoutBadgeRows(buildSql(7))
    let same = committed == fresh
    if not same:
      let at = firstDifference(committed, fresh)
      echo "fixtures: ", path, " differs from buildSql(7) at byte ", at,
        " (", committed.len, " vs ", fresh.len, " bytes), outside the badge block"
      echo "  committed: ", excerpt(committed, at)
      echo "  fresh:     ", excerpt(fresh, at)
    check same

  test "the committed badge block keeps the v1 shape the import ETL reads":
    ## `tools/import/main.nim:1083` expands `medal:<unit>` into v2 thresholds and
    ## `:1056` keeps `tournament:<id>` event medals, so a regenerated fixture
    ## without those prefixes would silently stop exercising the import path.
    let committed = readFile(committedFixturePath())
    check committed.contains("'medal:games', 'volume'")
    check committed.contains("'medal:rank', 'rank'")
    check committed.contains("'tournament:cd34cb19-8a6e-4c02-9ac6-e5420ec4c635'")
    check committed.contains("-- v1 stores one row per ladder")