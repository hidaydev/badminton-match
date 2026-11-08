import std/[base64, json, os, sysrand]
import cli
import db/db
import share/crypto
import share/store

const
  program = "sharekeys"
  usage = """Usage: sharekeys <command> [options]

  generate [--id <key-id>]
      Print a new 32-byte key as a SHARE_CODE_KEYS entry.

  rotate --from <key-id> --to <key-id> [--dry-run]
      Re-encrypt every link still sealed with --from under the active key.
      Requires MAJADU_PG_DSN, SHARE_CODE_KEYS and SHARE_CODE_ACTIVE_KEY_ID.
      Safe to run twice: rows already on the target key are skipped."""

proc generate(keyId: string) =
  var bytes: array[32, byte]
  if not urandom(bytes):
    fail(program, "cannot read random bytes")
  var raw = newString(bytes.len)
  for index in 0 ..< bytes.len:
    raw[index] = char(bytes[index])
  echo $(%*{keyId: encode(raw)})
  echo "# add this to SHARE_CODE_KEYS, then set SHARE_CODE_ACTIVE_KEY_ID=" & keyId

## Exported for `tools/sharekeys/tests/sharekeys_test.nim` (D-5): `main` reads
## the process command line, so the only way to drive argument handling without
## a second binary is to re-execute the test binary with a probe variable set.
proc main*() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let command = paramStr(1)
  var keyId = "1"
  var fromId = ""
  var toId = ""
  var dryRun = false
  for (flag, value) in flags(program, 2, ["--id", "--from", "--to"]):
    case flag
    of "--id":
      keyId = value
    of "--from":
      fromId = value
    of "--to":
      toId = value
    of "--dry-run":
      dryRun = true
    else:
      usageFail(program, "unknown argument: " & flag)

  case command
  of "generate":
    generate(keyId)
  of "rotate":
    if fromId.len == 0 or toId.len == 0:
      usageFail(program, "rotate needs --from and --to")
    let dsn = dsnOrFail(program)
    let keyring = loadKeyring(getEnv("SHARE_CODE_KEYS"),
      getEnv("SHARE_CODE_ACTIVE_KEY_ID"))
    if dryRun:
      echo "sharekeys: dry run, nothing written"
      quit(0)
    let database = openDb(dsn, 1)
    try:
      let rotated = rotateKeys(database, keyring, fromId, toId)
      echo "sharekeys: re-encrypted " & $rotated & " link(s) from key " &
        fromId & " to " & toId
    finally:
      database.close()
  else:
    echo usage
    quit(2)

when isMainModule:
  main()
