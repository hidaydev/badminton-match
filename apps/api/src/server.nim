import std/[locks, monotimes, os, strutils, times]
import mummy
import logger
import metrics
import uuidv7

type
  ServerConfig* = object
    port*: Port
    drainMs*: int
    shutdownTimeoutMs*: int
    testRoutes*: bool
    ## Zero keeps the internal metrics listener off.
    metricsPort*: int

  RouteResult* = object
    status*: int
    body*: string

const
  jsonType = "application/json"

proc requirePositiveInt(name: string, allowZero = false): int =
  let raw = getEnv(name)
  if raw.len == 0:
    raise newException(ValueError, name & " is required")
  try:
    result = parseInt(raw)
  except ValueError:
    raise newException(ValueError, name & " must be an integer")
  if result < 0 or (result == 0 and not allowZero):
    raise newException(ValueError, name & " must be positive")

proc loadMetricsPort*(): int =
  ## The listener is optional, but a value that cannot be a port refusal to
  ## start is better than a typo that silently hides every metric.
  let raw = getEnv("MAJADU_METRICS_PORT").strip()
  if raw.len == 0:
    return 0
  try:
    result = parseInt(raw)
  except ValueError:
    raise newException(ValueError, "MAJADU_METRICS_PORT must be an integer")
  if result < 1 or result > 65535:
    raise newException(ValueError, "MAJADU_METRICS_PORT must be 1..65535")

proc loadConfig*(): ServerConfig =
  ## Reads the process contract from the environment. No hidden defaults for
  ## the listen port and the drain window: a missing value refuses startup.
  let port = requirePositiveInt("MAJADU_PORT")
  if port > 65535:
    raise newException(ValueError, "MAJADU_PORT must be <= 65535")
  result.port = Port(port)
  result.drainMs = requirePositiveInt("MAJADU_DRAIN_MS", allowZero = true)
  let timeoutRaw = getEnv("MAJADU_SHUTDOWN_TIMEOUT_MS")
  if timeoutRaw.len == 0:
    result.shutdownTimeoutMs = 30000
  else:
    result.shutdownTimeoutMs = requirePositiveInt("MAJADU_SHUTDOWN_TIMEOUT_MS")
  # Compiled out of a release build: the stub handler, and the env read that
  # enables it, must not exist in the binary that serves the product.
  when defined(release):
    result.testRoutes = false
  else:
    result.testRoutes = getEnv("MAJADU_TEST_ROUTES") == "1"
  if result.testRoutes:
    # The flag replaces the whole router with a stub that answers 200 on
    # /healthz for every real endpoint returning 404. It must never reach a
    # release configuration, so any production signal refuses startup.
    let redirect = getEnv("OIDC_REDIRECT_URI")
    if redirect.startsWith("https://") or
        getEnv("MAJADU_COOKIE_SECURE") == "1" or
        getEnv("MAJADU_ENV") == "prod":
      raise newException(ValueError,
        "MAJADU_TEST_ROUTES=1 refuses a release configuration")
  # The clock switch is compiled out of a release build; in a debug build a
  # pinned clock beside a production signal is refused here, because the
  # application and PostgreSQL would disagree about "now" with no error.
  when not defined(release):
    if getEnv("MAJADU_NOW").len > 0 and
        (getEnv("MAJADU_ENV") == "prod" or
         getEnv("MAJADU_TEST_ROUTES") == "1"):
      raise newException(ValueError,
        "MAJADU_NOW pins the clock and cannot run with MAJADU_ENV=prod")
  result.metricsPort = loadMetricsPort()

var
  registryLock: Lock
  registry: Metrics

initLock(registryLock)

# The audit id of the request being served on this thread. `route()` starts one
# per request, every audit wrapper reads it, and the access log prints it, so a
# 500 can be paired with the rows of the write that preceded it. Each connection
# is served on a single worker thread, so a threadvar cannot leak between
# requests.
var activeRequestId {.threadvar.}: string
var activeRequestStart {.threadvar.}: MonoTime
var requestTimed {.threadvar.}: bool

proc beginRequest*() =
  ## Starts one id for the request this thread is about to serve. A nested call
  ## would break the correlation, so only the request chain calls it.
  activeRequestId = uuidv7()
  activeRequestStart = getMonoTime()
  requestTimed = true

proc currentRequestId*(): string =
  ## The id of the request being served, empty outside one. `recordAudit` turns
  ## an empty value into the historical `-`, so a CLI caller still writes a row.
  activeRequestId

proc recordResponse*(verb, path: string, status: int, label = "",
                     requestId = ""): string =
  ## One counter and one access-log line per answer. The label is the route
  ## template, never the raw path, so a share code, slug or id cannot become a
  ## series. Unmatched paths share one bucket: a scanner would otherwise mint a
  ## new series per request and grow the registry without bound.
  ##
  ## The request chain already computed the quota label from the contract shape
  ## (and `/unmatched` for anything outside it), so an explicit label wins even
  ## on a 404. That keeps the limiter bucket and the metric series named the
  ## same way. A direct caller without a request leaves the label empty, and a
  ## 404 then falls back to one shared `unmatched` series.
  ##
  ## The rendered line is returned so a test can prove it carries the same id
  ## as the audit rows written while serving that request.
  let routeLabel =
    if label.len > 0: label
    elif status == 404: "unmatched"
    else: templateRoute(path)
  # The elapsed time of the request this worker just served, labelled the same
  # way as the counter, so "p95 of the session detail route" is answerable from
  # the process itself. A direct caller of `recordResponse` (a suite) has no
  # start mark and records nothing.
  let elapsedSeconds =
    if requestTimed:
      float(inNanoseconds(getMonoTime() - activeRequestStart)) / 1_000_000_000.0
    else:
      -1.0
  withLock registryLock:
    registry.inc("http_requests_total",
      [("method", verb), ("route", routeLabel), ("status", $status)])
    if elapsedSeconds >= 0:
      registry.observe("http_request_duration_seconds", elapsedSeconds,
        [("route", routeLabel)])
  result = renderLog("info", "request",
    [("method", verb), ("route", routeLabel), ("status", $status),
     ("request_id", requestId)])
  stdout.writeLine result

proc recordIdentitySource*(source: string) =
  ## Every request records how the limiter named its caller. `cookie` is a
  ## session that resolved, `header` an address a trusted proxy asserted, and
  ## `peer` the raw TCP address. A production that answers almost everything
  ## with `peer` is one shared bucket behind the CDN, which is exactly the
  ## degradation no other metric shows.
  withLock registryLock:
    registry.inc("identity_resolution", [("source", source)])

proc recordPool*(size, available, inUse: int) =
  ## The pool is the resource a slow query exhausts first, and the one number a
  ## 503 from `DbPoolTimeout` should have been predicted by. Sampled on every
  ## answer, so a scrape reads the state of the last request instead of a value
  ## nobody updated.
  withLock registryLock:
    registry.setGauge("db_pool_size", float(size))
    registry.setGauge("db_pool_available", float(available))
    registry.setGauge("db_pool_in_use", float(inUse))

proc renderServerLog*(level: mummy.LogLevel,
                      args: openArray[string]): string =
  ## mummy's own lines ("Handler exception", "Dropped connection, body too
  ## large") rendered as the same JSON object as the application's. One parser
  ## reads the journal, and the line carries the request id of the request the
  ## worker thread was serving.
  var text = ""
  for arg in args:
    text.add(arg)
  let name =
    case level
    of mummy.DebugLevel: "debug"
    of mummy.InfoLevel: "info"
    of mummy.ErrorLevel: "error"
  renderLog(name, "server", [("detail", text),
    ("request_id", currentRequestId())])

proc structuredLogHandler*(level: mummy.LogLevel,
                           args: varargs[string]) {.gcsafe.} =
  ## Installed on `newServer`, so mummy cannot write an unstructured line.
  {.cast(gcsafe).}:
    stdout.writeLine renderServerLog(level, args)

proc metricsText*(): string {.gcsafe.} =
  ## Prometheus text exposition for the internal listener. The registry holds a
  ## table, which Nim refuses to call gcsafe for a global; the cast is sound
  ## because every read and write happens under `registryLock`, so a scrape
  ## never observes a half-written table.
  {.cast(gcsafe).}:
    withLock registryLock:
      result = registry.render()

proc metricsHandler*(): RequestHandler =
  ## `/metrics` and nothing else. Bind this server to loopback; the public
  ## socket must never carry it.
  result = proc(request: Request) {.gcsafe.} =
    if request.httpMethod == "GET" and request.path == "/metrics":
      request.respond(200, @[("Content-Type", "text/plain; version=0.0.4")],
        metricsText())
    else:
      request.respond(404, @[("Content-Type", "application/json")],
        """{"error":"not_found"}""")

proc route*(path: string, testRoutes: bool): RouteResult =
  case path
  of "/healthz":
    # A stub that answered plain `ok` made every probe report a healthy API
    # while each real endpoint was 404. The status field names the skeleton.
    if testRoutes:
      RouteResult(status: 200, body: """{"status":"stub"}""")
    else:
      RouteResult(status: 200, body: """{"status":"ok"}""")
  of "/__test/slow":
    if testRoutes:
      RouteResult(status: 200, body: """{"slept":700}""")
    else:
      RouteResult(status: 404, body: """{"error":"not_found"}""")
  else:
    RouteResult(status: 404, body: """{"error":"not_found"}""")

proc makeHandler*(testRoutes: bool): RequestHandler =
  result = proc(request: Request) {.gcsafe.} =
    var outcome: RouteResult
    if request.path == "/__test/slow" and testRoutes:
      # Exercise the drain window in integration tests only.
      sleep(700)
    outcome = route(request.path, testRoutes)
    request.respond(
      outcome.status,
      @[("Content-Type", jsonType)],
      outcome.body,
    )

proc newApiServer*(config: ServerConfig, workerThreads: int): Server =
  newServer(makeHandler(config.testRoutes), workerThreads = workerThreads)
