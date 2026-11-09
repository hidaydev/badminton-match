import std/[os, strutils, unittest]
import ../harness

# QA-24: a contributor who follows CONTRIBUTING installs the toolchain the
# project does not use, and a reviewer who follows the pull request checklist
# cannot see that e2e, coverage and mutation are part of the gate. These cases
# read the three files that have to agree and fail on the first disagreement.

proc between(text, start, stop: string): string =
  let first = text.find(start)
  if first < 0:
    return ""
  let rest = text[first + start.len .. ^1]
  let last = rest.find(stop)
  if last < 0:
    return ""
  result = rest[0 ..< last]

proc nodeVersion(): string =
  ## The first `node-version: X` in ci.yml. A workflow that pins the toolchain in
  ## several jobs must pin the same version, so the guard below compares them all.
  let workflow = readFile(repoDir / ".github" / "workflows" / "ci.yml")
  for line in workflow.splitLines:
    let trimmed = line.strip
    if trimmed.startsWith("node-version:"):
      return trimmed["node-version:".len .. ^1].strip
  ""

proc pnpmVersion(): string =
  let manifest = readFile(repoDir / "package.json")
  let spec = between(manifest, "\"packageManager\": \"pnpm@", "\"")
  spec

suite "contributor docs match the toolchain":
  test "CONTRIBUTING names the Node version CI uses":
    let version = nodeVersion()
    check version.len > 0
    let contributing = readFile(repoDir / "CONTRIBUTING.md")
    check contributing.contains("| Node.js | " & version & " |")

  test "CONTRIBUTING names the pnpm version package.json pins":
    let version = pnpmVersion()
    check version.len > 0
    let contributing = readFile(repoDir / "CONTRIBUTING.md")
    check contributing.contains("| pnpm | " & version & " |")

  test "every CI job pins the same Node version":
    let workflow = readFile(repoDir / ".github" / "workflows" / "ci.yml")
    let expected = nodeVersion()
    for line in workflow.splitLines:
      let trimmed = line.strip
      if trimmed.startsWith("node-version:"):
        check trimmed["node-version:".len .. ^1].strip == expected

  test "the pull request checklist names every gate the workflows run":
    let checklist = readFile(repoDir / ".github" / "pull_request_template.md")
    for command in ["./task check", "./task test", "./task build",
                    "./task contract-check", "pnpm check", "./task e2e",
                    "./task coverage", "./task mutation"]:
      check checklist.contains(command)
