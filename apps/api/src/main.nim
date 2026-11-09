import std/[atomics, cpuinfo, json, net, os, posix, strutils]
import mummy
import app
import build_info
import clock
import config as edgeConfig
import logger
import db/db
import live
import security_headers
import server
import account/infrastructure/oidc
import platform/config/store
import share/crypto

var shutdownRequested {.global.}: Atomic[bool]

proc onSignal(sig: cint) {.noconv.} =
  shutdownRequested.store(true, moRelaxed)

type
  ShutdownArgs = object
    server: Server
    drainMs: int
    timeoutMs: int

proc shutdownWatcher(args: ShutdownArgs) {.thread.} =
  while not shutdownRequested.load(moRelaxed):
    sleep(50)
  # Let in-flight requests finish before the listening socket goes away.
  sleep(args.drainMs)
  args.server.close()
  # Hard bound: if close() cannot finish, do not hang forever.
  sleep(args.timeoutMs)
  {.cast(gcsafe).}:
    logError("shutdown timed out")
  quit(1)

type
  MetricsArgs = object
    server: Server
    port: Port

proc serveMetrics(args: MetricsArgs) {.thread.} =
  ## The registry answers on loopback only, so the public socket stays free of
  ## it and no proxy needs a rule pointing here.
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError as error:
    # A failed bind must be visible: the process keeps serving the public API
    # without metrics, and only this line says why.
    {.cast(gcsafe).}:
      logError("metrics listener stopped", [("detail", error.msg)])

proc timeoutFromEnv(name: string, fallback: int): int =
  ## The web bounds belong to this process, not to `db.openDb`: a malformed
  ## value falls back to the documented default instead of refusing to start,
  ## because losing the bound to a typo would be the failure it prevents.
  let raw = getEnv(name).strip()
  if raw.len == 0:
    return fallback
  try:
    result = parseInt(raw)
  except ValueError:
    result = fallback
  if result < 0:
    result = fallback

type
  BootedApi* = object
    ## What `main` needs from a booted process: the installed handler and the
    ## two body limits, both decided once from the config snapshot.
    handler*: RequestHandler
    guardBytes*: int
    socketBytes*: int

proc bootHandler*(config: ServerConfig, threads: int): BootedApi =
  ## Wires the real application. Every dependency is required here so a
  ## misconfigured process refuses to start instead of serving 500s.
  ##
  ## Exported for `apps/api/tests/boot_contract_test.nim` (D-5): `main()` cannot
  ## be entered from a test without binding a port, and the order of the refusal
  ## checks is the contract that keeps a misconfigured process off the database.
  # `loadConfig` already refuses this pair for the process entry point, but this
  # is also the door a test or a second entry point knocks on with a hand built
  # config. A stub that answers 200 on `/healthz` while every real route,
  # `/readyz` included, answers 404 must never be wired in production.
  if config.testRoutes and getEnv("MAJADU_ENV") == "prod":
    raise newException(ValueError,
      "MAJADU_TEST_ROUTES=1 refuses MAJADU_ENV=prod")
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  # The limiter's anonymous identity is whatever address the edge asserts. A
  # production process that trusts no peer would key every anonymous caller by
  # the CDN address, so it refuses instead of silently collapsing the audience
  # into one bucket. The line below is the other half: it names the source a
  # deployment actually resolved at startup.
  let trusted = edgeConfig.trustedProxies()
  if getEnv("MAJADU_ENV") == "prod" and trusted.len == 0:
    raise newException(ValueError,
      "MAJADU_TRUSTED_PROXIES must name the edge peer in production")
  logInfo("identity source", [
    ("source", if trusted.len > 0: "header" else: "peer"),
    ("trustedProxies", $trusted.len)])
  # A worker can need a second connection while it already holds one: a `tx`
  # body that calls a `Db` helper. With exactly one connection per worker every
  # worker can hold its only connection, and the nested call waits forever.
  # Two spare connections bound the pool while turning that deadlock into a
  # short queue; the pool is still per process, not per request.
  const poolHeadroom = 2
  # The web caps are applied only here, on the API pool. CLI tools call
  # `openDb` without them so a deploy migration or a cutover ETL is not killed
  # by a request timeout.
  let database = openDb(dsn, threads + poolHeadroom,
    statementTimeoutMs = timeoutFromEnv("MAJADU_DB_STATEMENT_TIMEOUT_MS",
      defaultStatementTimeoutMs),
    lockTimeoutMs = timeoutFromEnv("MAJADU_DB_LOCK_TIMEOUT_MS",
      defaultLockTimeoutMs),
    acquireTimeoutMs = timeoutFromEnv("MAJADU_DB_ACQUIRE_TIMEOUT_MS",
      defaultAcquireTimeoutMs))
  let oidc = loadOidcConfig()
  let keyring = loadKeyring(getEnv("SHARE_CODE_KEYS"),
    getEnv("SHARE_CODE_ACTIVE_KEY_ID"))
  # Loading the snapshot here refuses to start when a registry key is missing.
  let config = newConfigCache(database)
  # The body limits are read from the same snapshot, so the socket cap and the
  # guard cannot drift from the config by a restart.
  let limits = bodyLimits(config.snapshot(database))
  logInfo("body limits", [
    ("guardBytes", $limits.guardBytes),
    ("socketBytes", $limits.socketBytes)])
  install(newApp(database, oidc, keyring, config))
  result = BootedApi(handler: handler(), guardBytes: limits.guardBytes,
    socketBytes: limits.socketBytes)

proc refuseStartup(message: string) {.noreturn.} =
  ## A misconfigured process must name the reason and exit, not leave an
  ## uncaught traceback as the only explanation in the logs.
  stderr.writeLine "majadu-api: " & message
  quit(1)

proc newApiServer*(booted: BootedApi, threads: int): Server =
  ## The one place the body cap reaches the socket, so a boot test can exercise
  ## the same wiring `main` uses instead of repeating it.
  newServer(booted.handler, websocketHandler(), workerThreads = threads,
    maxBodyLen = booted.socketBytes, logHandler = structuredLogHandler)

proc main() =
  var config: ServerConfig
  try:
    config = loadConfig()
  except ValueError as error:
    refuseStartup(error.msg)
  let threads = max(countProcessors(), 2)
  # One line names every switch that changes behaviour, so a line pasted from a
  # test env file is visible at boot instead of in the symptoms.
  logInfo("startup flags", [
    ("testRoutes", $config.testRoutes),
    ("clockPinned", $clockPinned())])
  var booted = BootedApi(handler: nil, socketBytes: socketBodyCeiling())
  if config.testRoutes:
    # The stub has no application guard, so its socket cap is the ceiling.
    booted.handler = makeHandler(config.testRoutes)
  else:
    try:
      booted = bootHandler(config, threads)
    except ValueError as error:
      refuseStartup(error.msg)
  let apiServer = newApiServer(booted, threads)

  var metricsWorker: Thread[MetricsArgs]
  if config.metricsPort > 0:
    createThread(metricsWorker, serveMetrics,
      MetricsArgs(
        server: newServer(metricsHandler(), workerThreads = 1),
        port: Port(config.metricsPort),
      ))

  signal(SIGTERM, onSignal)
  signal(SIGINT, onSignal)

  var watcher: Thread[ShutdownArgs]
  createThread(
    watcher,
    shutdownWatcher,
    ShutdownArgs(
      server: apiServer,
      drainMs: config.drainMs,
      timeoutMs: config.shutdownTimeoutMs,
    ),
  )

  logInfo("listening", values = [
    ("port", %config.port.int),
    ("metricsPort", %config.metricsPort),
    ("build", parseJson(buildInfoJson(threads))),
  ])
  try:
    apiServer.serve(config.port, "0.0.0.0")
  except MummyError as error:
    logError("serve failed", [("detail", error.msg)])
    quit(1)

  # serve() returns once close() finishes draining. Exit without joining the
  # watcher: it is intentionally parked on the hard-timeout sleep.
  quit(0)

when isMainModule:
  main()
