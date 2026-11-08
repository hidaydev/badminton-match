## Mutation testing, in house (D-14). A line of coverage proves a line ran; a
## killed mutant proves an assertion would notice if it stopped being right.
##
## The manifest is a plain text file so a reviewer can read every mutant in a
## diff, and each entry is checked before anything is compiled: a `find`
## string that appears zero times or twice is an error, because a silent
## no-op or a patch in the wrong place would report a false kill.
##
##   ./task mutation                  run every entry in the manifest
##   ./task mutation --dry-run        validate the manifest only
##   ./task mutation --only tools/    run entries whose file starts with a prefix
##   ./task mutation --list           print the manifest and exit
##
## Exit codes: 0 every survivor is allowlisted, 1 an unlisted survivor or a
## timed out suite, 2 the command line or the manifest is wrong.

import std/[algorithm, os, osproc, sequtils, strutils]
import clock

const
  program = "mutation"
  usage = """Usage: mutation [--dry-run] [--list] [--only PREFIX] [--timeout SECONDS]

Applies each mutant from tools/mutation/manifest.txt to a backup, runs the
owning suite, restores the file, and reports killed, survived or timed out.
A survivor is allowed only when tools/mutation/survivors.txt names it with an
owner and a reason."""

type
  Entry = object
    id: string
    file: string
    suite: string
    find: string
    replace: string

  Survivor = object
    id: string
    owner: string
    reason: string

const manifestRelative = "tools/mutation/manifest.txt"
const survivorsRelative = "tools/mutation/survivors.txt"
const separator = " | "

proc repositoryRoot(): string =
  result = getEnv("REPO_ROOT")
  if result.len == 0:
    result = getCurrentDir()

proc cacheDir(): string =
  let worktree = getEnv("WORKTREE", "mutation")
  repositoryRoot() / ".cache" / worktree / "mutation"

proc usageFail(message: string) {.noreturn.} =
  stderr.writeLine program & ": " & message
  stderr.writeLine usage
  quit(2)

proc runtimeFail(message: string) {.noreturn.} =
  stderr.writeLine program & ": " & message
  quit(1)

proc splitFields(line: string; path: string; lineNumber, expected: int): seq[string] =
  result = line.split(separator)
  if result.len != expected:
    runtimeFail(path & ":" & $lineNumber & ": expected " & $expected &
      " fields separated by '" & separator & "', found " & $result.len)

proc loadManifest(path: string): seq[Entry] =
  if not fileExists(path):
    runtimeFail("no manifest at " & path)
  var lineNumber = 0
  for raw in lines(path):
    inc lineNumber
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = splitFields(line, path, lineNumber, 5)
    var entry = Entry(id: fields[0].strip(), file: fields[1].strip(),
      suite: fields[2].strip(), find: fields[3], replace: fields[4])
    for (name, value) in [("id", entry.id), ("file", entry.file),
                          ("suite", entry.suite)]:
      if value.len == 0:
        runtimeFail(path & ":" & $lineNumber & ": " & name & " is empty")
    if entry.find.len == 0:
      runtimeFail(path & ":" & $lineNumber & ": find is empty")
    if entry.find == entry.replace:
      runtimeFail(path & ":" & $lineNumber & ": find and replace are identical")
    result.add entry

proc loadSurvivors(path: string): seq[Survivor] =
  if not fileExists(path):
    return
  var lineNumber = 0
  for raw in lines(path):
    inc lineNumber
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = splitFields(line, path, lineNumber, 3)
    result.add Survivor(id: fields[0].strip(), owner: fields[1].strip(),
      reason: fields[2].strip())

proc occurrences(haystack, needle: string): int =
  var index = haystack.find(needle)
  while index >= 0:
    inc result
    index = haystack.find(needle, index + needle.len)

proc backupPath(entry: Entry): string =
  ## The cache keeps one backup per file, so a crash mid-run leaves enough on
  ## disk to restore the tree on the next start.
  cacheDir() / "backup" / entry.file.replace('/', '_')

proc restoreLeftovers(entries: seq[Entry]) =
  for entry in entries:
    let backup = backupPath(entry)
    if fileExists(backup):
      writeFile(repositoryRoot() / entry.file, readFile(backup))
      removeFile(backup)
      stderr.writeLine program & ": restored " & entry.file &
        " from a previous interrupted run"

proc validate(entries: seq[Entry]): int =
  for entry in entries:
    let path = repositoryRoot() / entry.file
    if not fileExists(path):
      stderr.writeLine program & ": " & entry.id & ": no such file " & entry.file
      inc result
      continue
    if not fileExists(repositoryRoot() / entry.suite):
      stderr.writeLine program & ": " & entry.id & ": no such suite " & entry.suite
      inc result
      continue
    let count = occurrences(readFile(path), entry.find)
    if count != 1:
      stderr.writeLine program & ": " & entry.id & ": find appears " & $count &
        " time(s) in " & entry.file & " (must be exactly one)"
      inc result

proc apply(entry: Entry): bool =
  ## Writes the file with exactly one replacement. Returns false when the find
  ## string is gone, which means the code moved since the manifest was reviewed.
  let path = repositoryRoot() / entry.file
  let source = readFile(path)
  let at = source.find(entry.find)
  if at < 0:
    return false
  let backup = backupPath(entry)
  createDir(backup.parentDir)
  writeFile(backup, source)
  writeFile(path, source[0 ..< at] & entry.replace &
    source[at + entry.find.len .. ^1])
  true

proc restore(entry: Entry) =
  let backup = backupPath(entry)
  if fileExists(backup):
    writeFile(repositoryRoot() / entry.file, readFile(backup))
    removeFile(backup)

proc runSuite(entry: Entry; timeoutSeconds: int;
    logPath: string): tuple[status: int, timedOut: bool] =
  ## The command goes through `sh` so its output lands in a log file instead of
  ## a pipe that can fill up while the test suite is still writing to it.
  let binary = cacheDir() / "bin" / entry.id
  createDir(binary.parentDir)
  let command = "nim c -r --hints:off --nimcache:" &
    quoteShell(cacheDir() / "nimcache") & " -o:" & quoteShell(binary) & " " &
    quoteShell(repositoryRoot() / entry.suite) &
    " >" & quoteShell(logPath) & " 2>&1"
  let process = startProcess("/bin/sh", args = @["-c", command],
    options = {poUsePath})
  let started = utcNowMillis()
  while process.running:
    if utcNowMillis() - started > timeoutSeconds.int64 * 1_000:
      process.terminate()
      sleep(200)
      if process.running:
        process.kill()
      discard process.waitForExit()
      process.close()
      return (status: -1, timedOut: true)
    sleep(50)
  let status = process.waitForExit()
  process.close()
  (status: status, timedOut: false)

proc main() =
  var dryRun = false
  var listOnly = false
  var only = ""
  var timeoutSeconds = 300
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--dry-run": dryRun = true
    of "--list": listOnly = true
    of "--only":
      inc index
      if index > paramCount():
        usageFail("--only needs a prefix")
      only = paramStr(index)
    of "--timeout":
      inc index
      if index > paramCount():
        usageFail("--timeout needs a number of seconds")
      try:
        timeoutSeconds = parseInt(paramStr(index))
      except ValueError:
        usageFail("--timeout needs a number of seconds, got '" &
          paramStr(index) & "'")
      if timeoutSeconds < 1:
        usageFail("--timeout must be at least one second")
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      usageFail("unknown argument: " & paramStr(index))
    inc index

  let manifestPath = repositoryRoot() / manifestRelative
  var entries = loadManifest(manifestPath)
  if only.len > 0:
    entries = entries.filterIt(it.file.startsWith(only) or
      it.id.startsWith(only))
    if entries.len == 0:
      runtimeFail("no manifest entry matches '" & only & "'")
  entries.sort(proc (a, b: Entry): int = cmp(a.id, b.id))

  if listOnly:
    for entry in entries:
      echo entry.id & "\t" & entry.file & "\t" & entry.suite
    quit(0)

  restoreLeftovers(entries)
  let invalid = validate(entries)
  if invalid > 0:
    runtimeFail($invalid & " invalid manifest entr(y/ies); nothing was run")
  if dryRun:
    echo program & ": manifest ok (" & $entries.len & " entries)"
    quit(0)

  let survivorsPath = repositoryRoot() / survivorsRelative
  let allowlist = loadSurvivors(survivorsPath)
  let logDir = cacheDir() / "logs"
  createDir(logDir)

  var killed, survived, timedOut, unlisted = 0
  for entry in entries:
    if not apply(entry):
      runtimeFail(entry.id & ": the find string disappeared from " & entry.file &
        " after validation")
    let logPath = logDir / (entry.id & ".log")
    var run: tuple[status: int, timedOut: bool]
    try:
      run = runSuite(entry, timeoutSeconds, logPath)
    finally:
      restore(entry)
    if run.timedOut:
      inc timedOut
      stderr.writeLine program & ": " & entry.id & " TIMEOUT after " &
        $timeoutSeconds & "s (log: " & logPath & ")"
    elif run.status == 0:
      inc survived
      var allowed = false
      for survivor in allowlist:
        if survivor.id == entry.id:
          allowed = true
          break
      if allowed:
        echo program & ": " & entry.id & " survived (allowlisted)"
      else:
        inc unlisted
        stderr.writeLine program & ": " & entry.id & " SURVIVED (not in " &
          survivorsRelative & ")"
    else:
      inc killed
      echo program & ": " & entry.id & " killed"

  echo program & ": " & $entries.len & " mutant(s): " & $killed & " killed, " &
    $survived & " survived, " & $timedOut & " timed out"
  if unlisted > 0:
    runtimeFail($unlisted & " survivor(s) are not allowlisted")
  if timedOut > 0:
    runtimeFail($timedOut & " suite(s) timed out: a timeout is not a kill")

when isMainModule:
  main()