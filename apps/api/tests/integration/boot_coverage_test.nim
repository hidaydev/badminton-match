## The boot tail: everything `bootHandler` does after its refusals.
##
## `apps/api/tests/boot_contract_test.nim` covers the refusals that happen
## before `openDb` (test routes in production, a missing DSN, no trusted proxy),
## so every case there returns before a connection. This suite covers the rest
## of the same routine against a real database: the pool, the OIDC config, the
## share keyring, the config snapshot, the ADR-018 one-community guard and
## `install()`.
##
## The suite never binds a port: `install()` assigns the process-wide App and
## registers the live hub, and `main()` is what listens.

import std/[net, options, os, strutils, unittest]
import db/db
import ../../src/main
import ../../src/server
import ../http_support

requireDatabase()

proc withEnv(values: openArray[(string, string)], work: proc()) =
  ## Every variable the case sets is cleared afterwards and restored if it was
  ## already set, so this suite cannot leak a production environment into a
  ## neighbour that shares the process.
  var previous: seq[(string, string)] = @[]
  for (name, value) in values:
    previous.add((name, getEnv(name)))
    if value.len == 0: delEnv(name)
    else: putEnv(name, value)
  try:
    work()
  finally:
    for (name, value) in previous:
      if value.len == 0: delEnv(name)
      else: putEnv(name, value)

proc bootEnv(environment: string,
             work: proc()): proc() =
  ## The environment a real boot needs beside the DSN: a client id and redirect
  ## for `loadOidcConfig`, the share keyring, and the tenancy environment.
  result = proc() =
    withEnv([
      ("OIDC_CLIENT_ID", "boot-coverage-client"),
      ("OIDC_REDIRECT_URI", "https://majadu.test/api/auth/callback"),
      ("SHARE_CODE_KEYS", keysJson),
      ("SHARE_CODE_ACTIVE_KEY_ID", "1"),
      ("MAJADU_ENV", environment),
      ("MAJADU_TRUSTED_PROXIES",
        if environment == "prod": "10.0.0.1" else: ""),
    ], work)

proc insertCommunity(db: Db, slug: string) =
  discard db.execUpdate(
    """insert into platform.community (slug, name, timezone)
       values ($1, $2, 'Asia/Jakarta')""",
    @[textParam(slug), textParam(slug)])

proc deleteCommunity(db: Db, slug: string) =
  discard db.execUpdate("delete from platform.community where slug = $1",
    @[textParam(slug)])

proc bootMessage(environment: string): string =
  ## What `bootHandler` refused with, or "" when it booted.
  var message = ""
  bootEnv(environment, proc() =
    try:
      discard bootHandler(ServerConfig(port: Port(8080)), 1)
    except ValueError as error:
      message = error.msg)()
  message

suite "bootHandler against a real database":
  test "two communities in production refuse with the one-community rule":
    # ADR-018: a production database may hold one community until RLS ships.
    # The message names the rule and the document, not only a count.
    let db = openDb(dsn(), 1)
    let suffix = $getCurrentProcessId()
    let first = "boot-coverage-a-" & suffix
    let second = "boot-coverage-b-" & suffix
    try:
      insertCommunity(db, first)
      insertCommunity(db, second)
      # The rule names the count this database actually holds, so the assertion
      # does not assume a template with no communities.
      let total = parseInt(db.queryOne(
        "select count(*)::int as total from platform.community").get.get("total"))
      check total >= 2
      let message = bootMessage("prod")
      checkpoint("boot message: " & message)
      check message.contains("ADR-018")
      check message.contains("one per production database")
      check message.contains($total & " communities")
    finally:
      deleteCommunity(db, first)
      deleteCommunity(db, second)
      db.close()

  test "one community boots: the pool, the config snapshot and install() run":
    # The success path. `install()` only assigns the process-wide App and
    # registers the hub, so this runs inside the suite without a listening
    # socket.
    let db = openDb(dsn(), 1)
    let slug = "boot-coverage-one-" & $getCurrentProcessId()
    try:
      insertCommunity(db, slug)
      var booted: BootedApi
      bootEnv("", proc() =
        booted = bootHandler(ServerConfig(port: Port(8080)), 1))()
      check booted.guardBytes > 0
      # The socket cap is the registry ceiling for the guard, so it can only be
      # greater than or equal to the configured body limit.
      check booted.socketBytes >= booted.guardBytes
    finally:
      deleteCommunity(db, slug)
      db.close()
