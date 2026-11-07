import std/[locks, os, strutils]
import mummy
import logger
import metrics

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
  result.testRoutes = getEnv("MAJADU_TEST_ROUTES") == "1"
  result.metricsPort = loadMetricsPort()

var
  registryLock: Lock
  registry: Metrics

initLock(registryLock)

proc recordResponse*(verb, path: string, status: int, label = "") =
  ## One counter and one access-log line per answer. The label is the route
  ## template, never the raw path, so a share code, slug or id cannot become a
  ## series. Unmatched paths share one bucket: a scanner would otherwise mint a
  ## new series per request and grow the registry without bound.
  ##
  ## The request chain already computed the template, so it passes it in; a
  ## direct caller without a request leaves it empty and it is derived here.
  let routeLabel =
    if status == 404: "unmatched"
    elif label.len > 0: label
    else: templateRoute(path)
  withLock registryLock:
    registry.inc("http_requests_total",
      [("method", verb), ("route", routeLabel), ("status", $status)])
  logInfo("request",
    [("method", verb), ("route", routeLabel), ("status", $status)])

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
