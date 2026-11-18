# SEC-05: `osv-scanner.toml` is the one place a HIGH advisory can pass, and
# nothing in this repository reads it. Upstream 2.7.0 treats a block without
# `ignoreUntil` as "always ignore" and rejects the WHOLE file when a key is
# unknown, so a single typo turns every exception off without failing anything.
# The scanner is not installed on a developer machine, so this suite parses the
# file itself instead of calling it.

import std/[os, strutils, times, unittest]
import ../harness

const
  exceptionFile = "osv-scanner.toml"
  blockHeader = "[[IgnoredVulns]]"
  allowedKeys = ["id", "ignoreUntil", "reason"]

type
  Entry = object
    lineNumber: int
    values: seq[(string, string)]

proc stripComment(line: string): string =
  ## Removes a `#` comment, but only when it starts outside a quoted value, so
  ## a reason that mentions `#` keeps its text.
  var inString = false
  for index, character in line.pairs:
    if character == '"':
      inString = not inString
    elif character == '#' and not inString:
      return line[0 ..< index]
  line

proc parseValue(raw: string): string =
  let value = raw.strip
  if value.len >= 2 and value[0] == '"' and value[^1] == '"':
    return value[1 .. ^2]
  value

proc parseEntries*(text: string): seq[Entry] =
  var current: Entry
  var open = false
  var lineNumber = 0
  for rawLine in text.splitLines:
    inc lineNumber
    let line = stripComment(rawLine).strip
    if line.len == 0:
      continue
    if line.startsWith(blockHeader):
      if open:
        result.add(current)
      current = Entry(lineNumber: lineNumber)
      open = true
      continue
    if not open:
      # A table that is not an exception block is outside this guard's scope.
      continue
    let equals = line.find('=')
    if equals < 0:
      current.values.add(("", line))
      continue
    current.values.add((line[0 ..< equals].strip, parseValue(line[equals + 1 .. ^1])))
  if open:
    result.add(current)

proc isDigitString(text: string): bool =
  text.len > 0 and text.allCharsInSet({'0' .. '9'})

proc isValidCalendarDate(text: string): bool =
  ## A real `YYYY-MM-DD` day, not just a string in that shape: 2026-02-30 is a
  ## date the upstream decoder also refuses.
  if text.len != 10 or text[4] != '-' or text[7] != '-':
    return false
  let year = text[0 .. 3]
  let month = text[5 .. 6]
  let day = text[8 .. 9]
  if not (isDigitString(year) and isDigitString(month) and isDigitString(day)):
    return false
  let yearNumber = parseInt(year)
  let monthNumber = parseInt(month)
  let dayNumber = parseInt(day)
  if monthNumber < 1 or monthNumber > 12 or dayNumber < 1:
    return false
  var perMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let leap = (yearNumber mod 4 == 0 and yearNumber mod 100 != 0) or
    yearNumber mod 400 == 0
  if leap:
    perMonth[1] = 29
  dayNumber <= perMonth[monthNumber - 1]

proc dateKey(text: string): (int, int, int) =
  (parseInt(text[0 .. 3]), parseInt(text[5 .. 6]), parseInt(text[8 .. 9]))

proc today(): (int, int, int) =
  let now = getTime().local
  (now.year, now.month.int, now.monthday)

proc label(entry: Entry, ordinal: int): string =
  ## Every message names the block, so a red build points at the entry and not
  ## at the file.
  var id = ""
  for (key, value) in entry.values:
    if key == "id":
      id = value
  if id.len > 0:
    "osv-scanner.toml:" & $entry.lineNumber & ": [[IgnoredVulns]] block " &
      $ordinal & " (id \"" & id & "\")"
  else:
    "osv-scanner.toml:" & $entry.lineNumber & ": [[IgnoredVulns]] block " & $ordinal

proc validate*(text: string, reference: (int, int, int)): seq[string] =
  ## Every rule this suite enforces, as a list of problems: upstream's hard
  ## failures first, then the ones that would leave a permanent exception.
  let entries = parseEntries(text)
  var ordinal = 0
  for entry in entries:
    inc ordinal
    let name = label(entry, ordinal)
    var values: seq[(string, string)]
    for (key, value) in entry.values:
      if key.len == 0:
        result.add(name & " has a line that is not `key = value`: " & value)
      elif key notin allowedKeys:
        # Upstream refuses the whole file on an unknown key, which switches off
        # every exception at once, so this is a failure and not a warning.
        result.add(name & " uses unknown key \"" & key &
          "\", which makes osv-scanner reject the entire file")
      else:
        values.add((key, value))
    for required in ["id", "ignoreUntil", "reason"]:
      var present = false
      for (key, value) in values:
        if key == required and value.strip.len > 0:
          present = true
      if not present:
        if required == "ignoreUntil":
          result.add(name & " is missing ignoreUntil, which upstream reads as " &
            "\"ignore forever\"")
        else:
          result.add(name & " is missing a non-empty " & required)
    for (key, value) in values:
      if key != "ignoreUntil" or value.len == 0:
        continue
      if not isValidCalendarDate(value):
        result.add(name & " has ignoreUntil \"" & value &
          "\", which is not a YYYY-MM-DD calendar date")
      elif dateKey(value) < reference:
        result.add(name & " expired on " & value &
          ", so the exception has to be removed or renewed")

proc realFile(): string =
  let path = repoDir / exceptionFile
  if fileExists(path):
    readFile(path)
  else:
    ""

suite "osv-scanner.toml exceptions":
  test "the repository exception file carries no permanent or malformed entry":
    let text = realFile()
    let entries = parseEntries(text)
    # A parser that reads nothing would pass every rule below, so the suite
    # proves it saw the dated picomatch exception before judging the file.
    check entries.len > 0
    check text.contains("GHSA-fc5q-39xc-vjpf")
    let problems = validate(text, today())
    for problem in problems:
      checkpoint(problem)
    check problems.len == 0

  test "a block without ignoreUntil is rejected and names its id":
    # Hermetic: pinned independently of the real file, which is what the
    # mutation check below relies on.
    let text = """
[[IgnoredVulns]]
id = "GHSA-test-nodate"
reason = "example"
"""
    let problems = validate(text, (2026, 11, 18))
    check problems.len == 1
    check problems[0].contains("GHSA-test-nodate")
    check problems[0].contains("missing ignoreUntil")

  test "an unknown key is rejected because upstream drops the whole file":
    let text = """
[[IgnoredVulns]]
id = "GHSA-test-key"
ignoreUntil = 2026-12-18
reason = "example"
effectiveUntil = 2026-12-18
"""
    let problems = validate(text, (2026, 11, 18))
    check problems.len == 1
    check problems[0].contains("effectiveUntil")
    check problems[0].contains("GHSA-test-key")

  test "a date that is not a real calendar day is rejected":
    for bad in ["2026-13-01", "2026-02-30", "2026-1-1", "tomorrow", "2026/12/18"]:
      let text = "[[IgnoredVulns]]\nid = \"GHSA-test-date\"\nignoreUntil = " &
        bad & "\nreason = \"example\"\n"
      let problems = validate(text, (2026, 11, 18))
      checkpoint(bad)
      check problems.len == 1
      check problems[0].contains("not a YYYY-MM-DD calendar date")

  test "a past date is red instead of a forgotten exception":
    let text = """
[[IgnoredVulns]]
id = "GHSA-test-past"
ignoreUntil = 2026-11-17
reason = "example"
"""
    let problems = validate(text, (2026, 11, 18))
    check problems.len == 1
    check problems[0].contains("expired on 2026-11-17")

  test "a quoted date, comments and blank lines are accepted":
    let text = """
# a comment line

[[IgnoredVulns]]
id = "GHSA-test-quoted"   # trailing comment
ignoreUntil = "2026-12-18"
reason = "example, with a # inside the text"
"""
    check validate(text, (2026, 11, 18)).len == 0

  test "a missing reason is rejected":
    let text = """
[[IgnoredVulns]]
id = "GHSA-test-noreason"
ignoreUntil = 2026-12-18
"""
    let problems = validate(text, (2026, 11, 18))
    check problems.len == 1
    check problems[0].contains("reason")
