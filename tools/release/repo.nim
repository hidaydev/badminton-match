## Thin git wrapper. Every command runs inside an explicit repository root so
## the release tool behaves the same from any working directory.
import std/[os, osproc, strutils]
import versioning

type GitResult* = object
  output*: string
  code*: int

proc runGit*(repo: string, args: seq[string]): GitResult =
  let command = "git " & quoteShellCommand(args)
  let (output, code) = execCmdEx(command, workingDir = repo)
  GitResult(output: output, code: code)

proc git*(repo: string, args: seq[string]): string =
  let outcome = runGit(repo, args)
  if outcome.code != 0:
    raise newException(OSError,
      "git " & args.join(" ") & " failed: " & outcome.output.strip())
  outcome.output

proc lastTag*(repo: string): string =
  ## Empty when the repository has no tag yet; the caller then walks every commit.
  let outcome = runGit(repo, @["describe", "--tags", "--abbrev=0"])
  if outcome.code != 0:
    return ""
  outcome.output.strip()

proc isDirty*(repo: string): bool =
  git(repo, @["status", "--porcelain"]).strip().len > 0

proc parseRecord(record: string): Commit =
  ## One `%x1e`-delimited record: hash, subject, body (`%x1f` separated), `%x1d`,
  ## then the blank line and file paths that `--name-only` appends.
  let marker = record.find('\x1d')
  if marker < 0:
    return Commit()
  let fields = record[0 ..< marker].split('\x1f', maxsplit = 2)
  if fields.len < 3 or fields[0].len == 0:
    return Commit()
  var paths: seq[string] = @[]
  for line in record[marker + 1 .. ^1].splitLines():
    let path = line.strip()
    if path.len > 0:
      paths.add path
  parseCommit(fields[0], fields[1], fields[2], paths)

proc logCommits*(repo: string, sinceTag: string): seq[Commit] =
  ## Commits since `sinceTag` (exclusive), or every commit when it is empty.
  ## Merge commits are skipped: their subject is never a change description.
  var args = @["log", "--no-merges", "--name-only",
    "--pretty=format:%x1e%H%x1f%s%x1f%b%x1d"]
  if sinceTag.len > 0:
    args.add sinceTag & "..HEAD"
  else:
    args.add "HEAD"
  for record in git(repo, args).split('\x1e'):
    if record.strip().len == 0:
      continue
    let commit = parseRecord(record)
    if commit.hash.len > 0:
      result.add commit
