import std/[atomics, cpuinfo, net, os, posix]
import mummy
import app
import build_info
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
  echo """{"level":"error","msg":"shutdown timed out"}"""
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

proc bootHandler(config: ServerConfig, threads: int): RequestHandler =
  ## Wires the real application. Every dependency is required here so a
  ## misconfigured process refuses to start instead of serving 500s.
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  # A worker can need a second connection while it already holds one: a `tx`
  # body that calls a `Db` helper. With exactly one connection per worker every
  # worker can hold its only connection, and the nested call waits forever.
  # Two spare connections bound the pool while turning that deadlock into a
  # short queue; the pool is still per process, not per request.
  const poolHeadroom = 2
  let database = openDb(dsn, threads + poolHeadroom)
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

  echo """{"level":"info","msg":"listening","port":""" & $config.port.int &
    ""","metricsPort":""" & $config.metricsPort &
    ""","build":""" & buildInfoJson(threads) & "}"
  try:
    apiServer.serve(config.port, "0.0.0.0")
  except MummyError as error:
    var detail = ""
    for c in error.msg:
      case c
      of '"': detail.add("\\\"")
      of '\\': detail.add("\\\\")
      of '\n': detail.add("\\n")
      else: detail.add(c)
    stderr.writeLine("{\"level\":\"error\",\"msg\":\"serve failed\",\"detail\":\"" &
      detail & "\"}")
    quit(1)

  # serve() returns once close() finishes draining. Exit without joining the
  # watcher: it is intentionally parked on the hard-timeout sleep.
  quit(0)

when isMainModule:
  main()
