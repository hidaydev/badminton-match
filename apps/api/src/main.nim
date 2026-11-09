import std/[atomics, cpuinfo, json, net, os, posix, strutils]
import mummy
import app
import build_info
import config as edgeConfig
import logger
import db/db
import live
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

proc bootHandler*(config: ServerConfig, threads: int): RequestHandler =
  ## Wires the real application. Every dependency is required here so a
  ## misconfigured process refuses to start instead of serving 500s.
  ##
  ## Exported for `apps/api/tests/boot_contract_test.nim` (D-5): `main()` cannot
  ## be entered from a test without binding a port, and the order of the refusal
  ## checks is the contract that keeps a misconfigured process off the database.
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
  install(newApp(database, oidc, keyring, config))
  result = handler()

proc main() =
  let config = loadConfig()
  let threads = max(countProcessors(), 2)
  let apiHandler =
    if config.testRoutes: makeHandler(config.testRoutes)
    else: bootHandler(config, threads)
  let apiServer = newServer(apiHandler, websocketHandler(), workerThreads = threads)

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
