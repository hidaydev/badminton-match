## The readiness refusals, exercised against a database of this run's own.
##
## The app cannot boot against a database with no `platform.config`, because
## `newConfigCache` loads the registry from it, so the empty-schema case boots
## against a migrated scratch database and then removes the relations `/readyz`
## demands, leaving only the config counter the route reads before it decides.
## Every destructive statement runs on the scratch database and the last case
## is the destructive one.

import std/[json, options, os, strutils, unittest]
import db/db
import ../http_support
import ../../../../tools/dbtools/main

const
  port = testPort(18107)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  migrationsDir = "db/migrations"
  seedsDir = "db/seeds"

proc databaseDsn(dsn, database: string): string =
  let query = dsn.find('?')
  let head = if query >= 0: dsn[0 ..< query] else: dsn
  let tail = if query >= 0: dsn[query .. ^1] else: ""
  let slash = head.rfind('/')
  if slash <= head.find("://") + 2:
    raise newException(ValueError, "MAJADU_PG_DSN has no database path: " & dsn)
  head[0 ..< slash] & "/" & database & tail

proc adminDsn(): string =
  let explicit = getEnv("MAJADU_PG_ADMIN_DSN")
  if explicit.len > 0:
    return explicit
  databaseDsn(getEnv("MAJADU_PG_DSN"), "postgres")

proc checkedName(name: string): string =
  for character in name:
    if character notin {'a' .. 'z', '0' .. '9', '_'}:
      raise newException(ValueError, "unsafe database name: " & name)
  name

proc expectNotReady(detail: string) =
  let response = call(baseUrl, HttpGet, "/readyz")
  expectProblem(response, 503, "NOT_READY")
  check response.json["detail"].getStr() == detail

var
  admin: Db
  scratch: Db
  scratchName: string
  bootVersion: string

proc bootstrap() =
  if getEnv("MAJADU_PG_DSN").len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  scratchName = checkedName("bm2_ready_" & $getCurrentProcessId())
  admin = openDb(adminDsn(), 1)
  discard admin.execUpdate("drop database if exists " & scratchName &
    " with (force)")
  discard admin.execUpdate("create database " & scratchName)
  scratch = openDb(databaseDsn(getEnv("MAJADU_PG_DSN"), scratchName), 1)
  migrate(scratch, migrationsDir)
  seed(scratch, seedsDir)
  bootVersion = scratch.queryOne(
    "select version from platform.config_version").get.get("version")
  delEnv("CUTOVER_SNAPSHOT_SHA256")
  startServer(newTestApp(scratch), port, baseUrl)

proc shutdown() =
  if scratch != nil:
    scratch.close()
    scratch = nil
  if admin != nil:
    discard admin.execUpdate("drop database if exists " & scratchName &
      " with (force)")
    admin.close()
    admin = nil

bootstrap()
try:
  suite "readiness on a scratch database":
    test "a dropped required relation is a schema refusal, and its return is 200":
      discard scratch.execUpdate("drop table platform.cutover_state")
      expectNotReady("schema is not migrated")

      # The shortest restore that satisfies the existence check is the table
      # itself; `/readyz` reads it only for the snapshot comparison below.
      discard scratch.execUpdate(
        """create table platform.cutover_state (
             id boolean primary key default true,
             snapshot_sha256 text,
             snapshot_taken_at timestamptz,
             etl_completed_at timestamptz,
             completed_at timestamptz,
             app_version text,
             rows_imported jsonb not null default '{}'::jsonb,
             constraint cutover_state_singleton check (id))""")
      expectStatus(call(baseUrl, HttpGet, "/readyz"), 200)

    test "an empty recorded snapshot stays ready even when one is expected":
      delEnv("CUTOVER_SNAPSHOT_SHA256")
      discard scratch.execUpdate("delete from platform.cutover_state")
      discard scratch.execUpdate(
        """insert into platform.cutover_state (id, snapshot_sha256)
           values (true, '')""")
      putEnv("CUTOVER_SNAPSHOT_SHA256", "be12-expected")
      expectStatus(call(baseUrl, HttpGet, "/readyz"), 200)
      delEnv("CUTOVER_SNAPSHOT_SHA256")
      discard scratch.execUpdate("delete from platform.cutover_state")

    test "a different recorded snapshot is a snapshot refusal":
      discard scratch.execUpdate(
        """insert into platform.cutover_state (id, snapshot_sha256)
           values (true, 'be12-recorded')""")
      putEnv("CUTOVER_SNAPSHOT_SHA256", "be12-expected")
      expectNotReady("database holds a different snapshot")
      delEnv("CUTOVER_SNAPSHOT_SHA256")
      discard scratch.execUpdate("delete from platform.cutover_state")

    test "a database with no application schema is not ready":
      # The config counter is the one relation the request path reads before
      # `/readyz` runs; everything else the list names is gone.
      discard scratch.execUpdate(
        """drop schema session, player, rating, auth, account, community,
                  dbtools cascade""")
      discard scratch.execUpdate("drop schema platform cascade")
      discard scratch.execUpdate("create schema platform")
      discard scratch.execUpdate(
        "create table platform.config_version (version bigint not null)")
      discard scratch.execUpdate(
        "insert into platform.config_version (version) values ($1::bigint)",
        @[textParam(bootVersion)])
      expectNotReady("schema is not migrated")
finally:
  shutdown()