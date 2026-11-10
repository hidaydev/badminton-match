## Bounded waits for the suites. A fixed `sleep` cannot be made reliable by
## adding more of it: under load the interval is too short and the test fails for
## a reason unrelated to the code under test (SQ-26). Every wait here polls a
## condition, returns as soon as it holds, and names the last observed state when
## the bound passes, so a red run says what it was still waiting for.

import std/[httpclient, monotimes, net, os, times]

## How often a condition is re-read. Short enough that a passing wait costs
## milliseconds, long enough that a failing one does not spin a core.
const pollIntervalMs* = 5

proc waitUntil*(condition: proc(): bool, describe: proc(): string,
                timeoutMs = 10000, pollMs = pollIntervalMs) =
  ## Returns as soon as `condition` holds; raises ValueError naming what the
  ## caller last saw when it does not hold within `timeoutMs`.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    if condition():
      return
    if getMonoTime() >= deadline:
      raise newException(ValueError, "condition did not hold within " &
        $timeoutMs & " ms; last observed state: " & describe())
    os.sleep(pollMs)

proc answersWithStatus*(url: string, status: int): bool =
  ## One probe of an HTTP endpoint. A transport error is `false`: a server that
  ## is still binding refuses the connection, which is a reason to wait.
  try:
    let client = newHttpClient(timeout = 1000)
    defer: client.close()
    result = client.get(url).code.int == status
  except CatchableError:
    result = false

proc waitForHttp*(url: string, status = 200, timeoutMs = 10000) =
  ## Waits for a booted server to answer `status` on `url`.
  waitUntil(proc(): bool = answersWithStatus(url, status),
    proc(): string = "GET " & url & " did not answer " & $status, timeoutMs)

proc acceptsConnections*(port: Port, address = "127.0.0.1"): bool =
  ## One probe of a listening socket. Used by suites whose stub is not an HTTP
  ## server, so "the port answers" is the readiness condition.
  try:
    let probe = newSocket()
    defer: probe.close()
    probe.connect(address, port)
    result = true
  except CatchableError:
    result = false
