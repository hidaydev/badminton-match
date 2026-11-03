import std/[os, strutils]
import mummy

type
  ServerConfig* = object
    port*: Port
    drainMs*: int
    shutdownTimeoutMs*: int
    testRoutes*: bool

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
