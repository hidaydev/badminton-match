import std/[base64, json, os, strutils, sysrand]
import db/db
import share/crypto
import share/store

const usage = """Usage: sharekeys <command> [options]

  generate [--id <key-id>]
      Print a new 32-byte key as a SHARE_CODE_KEYS entry.

  rotate --from <key-id> --to <key-id> [--dry-run]
      Re-encrypt every link still sealed with --from under the active key.
      Requires MAJADU_PG_DSN, SHARE_CODE_KEYS and SHARE_CODE_ACTIVE_KEY_ID.
      Safe to run twice: rows already on the target key are skipped."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "sharekeys: " & message
  quit(2)

proc generate(keyId: string) =
  var bytes: array[32, byte]
  if not urandom(bytes):
    fail "cannot read random bytes"
  var raw = newString(bytes.len)
  for index in 0 ..< bytes.len:
    raw[index] = char(bytes[index])
  echo $(%*{keyId: encode(raw)})
  echo "# add this to SHARE_CODE_KEYS, then set SHARE_CODE_ACTIVE_KEY_ID=" & keyId

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let command = paramStr(1)
  var keyId = "1"
  var fromId = ""
  var toId = ""
  var dryRun = false
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--id":
      index.inc; keyId = paramStr(index)
    of "--from":
      index.inc; fromId = paramStr(index)
    of "--to":
      index.inc; toId = paramStr(index)
    of "--dry-run":
      dryRun = true
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc

  case command
  of "generate":
    generate(keyId)
  of "rotate":
    if fromId.len == 0 or toId.len == 0:
      fail "rotate needs --from and --to"
    let dsn = getEnv("MAJADU_PG_DSN")
    if dsn.len == 0:
      fail "MAJADU_PG_DSN is required"
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
