## Test-only helper for running a job as the role production runs it.
##
## A suite that opens the plain DSN runs as the developer's own role, and in CI
## as `postgres`. The owner bypasses row security (the policy set enables it and
## never forces it), so a nightly job that has lost its tenant scoping deletes
## and writes nothing while every assertion on the owner DSN still passes. That
## is the silent failure this release exists to prevent, so the job cases have to
## run as `bm2_app` to mean anything.
##
## The helper deliberately sets no tenant. Every statement inside `body` reaches
## the database the way the tool reaches it: through a facade the tool builds
## itself, and on tables the tool names. Pre-setting the setting here would let
## a job that lost its own scoping still pass.
##
## Nothing here survives the call: the body runs inside one transaction that is
## always rolled back. A probe that committed would leave rows behind exactly on
## the failure path it is meant to catch.

import std/options
import db/db

proc canAssumeAppRole*(conn: DbConn): bool =
  ## Whether this connection's role may `set role bm2_app`. A superuser may, and
  ## so may a role that is a member of `bm2_app`; `bm2_owner` is neither, which
  ## is why a suite cannot run this helper on the owner DSN.
  ##
  ## Asked about the connection the caller already holds rather than about a
  ## `Db`: a pool of one that checked out a second connection to answer would
  ## wait until the acquire timeout and fail with a message about the pool
  ## instead of about the role.
  let row = conn.queryOne(
    """select (select rolsuper from pg_roles where rolname = current_user)
              or pg_has_role(current_user, 'bm2_app', 'member') as allowed""")
  row.isSome and row.get.getBool("allowed")

proc asApp*(db: Db, body: proc(app: Db, conn: DbConn)) =
  ## Runs `body` on this pool's one connection as `bm2_app`, inside a transaction
  ## that is rolled back.
  ##
  ## `app` is a facade bound to that connection, so a statement the body issues
  ## joins the same transaction and the same role, and `app.scoped(id)` builds
  ## the same facade the tool builds in production. `conn` is there for a probe
  ## that has to count rows itself. The pool must be size 1 for the duration: any
  ## other checkout while the body runs waits until the acquire timeout.
  discard db.read(proc(conn: DbConn): bool =
    doAssert canAssumeAppRole(conn),
      "this suite needs a DSN whose role is a superuser or a member of bm2_app"
    # `execUpdate`, not `query`: these are commands with no result rows, and
    # `query` refuses anything that is not a tuple result.
    discard conn.execUpdate("begin")
    try:
      discard conn.execUpdate("set local role bm2_app")
      body(db.boundTo(conn), conn)
      false
    finally:
      discard conn.execUpdate("rollback"))
