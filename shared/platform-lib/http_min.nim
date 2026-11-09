import std/[monotimes, nativesockets, net, strutils, times, uri]

type HttpMinError* = object of CatchableError

## One bound for connect, send and the whole read. A peer that accepts the
## connection and stops sending used to block the calling worker thread
## forever, and in the JWKS path that blocked every other login behind it
## (SQ-09). Callers that must answer instead of raising catch `HttpMinError`.
const defaultTimeoutMs* = 10000

proc elapsedMs(started: MonoTime): int =
  (getMonoTime() - started).inMilliseconds.int

proc remainingMs(deadline: MonoTime): int =
  ## Milliseconds left before the request as a whole is abandoned. The bound is
  ## on the exchange rather than on one `recv`, so a peer that drips one byte
  ## at a time cannot hold a worker open by staying just under each read.
  result = (deadline - getMonoTime()).inMilliseconds.int

proc httpRequest*(url, verb: string, body = "",
                  headers: openArray[(string, string)] = [],
                  timeoutMs = defaultTimeoutMs): (int, string) =
  ## Minimal HTTP/1.1 client for plain http (tests, OIDC stub). HTTPS goes
  ## through std/httpclient when the binary is built with -d:ssl.
  let started = getMonoTime()
  let deadline = started + initDuration(milliseconds = timeoutMs)
  let parsed = parseUri(url)
  if parsed.scheme != "http":
    raise newException(HttpMinError, "httpRequest only supports http://")
  if parsed.hostname.len == 0:
    raise newException(HttpMinError, "missing host in " & url)
  let portNumber = if parsed.port.len == 0: 80 else: parseInt(parsed.port)
  let port = Port(portNumber)
  let target = if parsed.path.len == 0: "/" else: parsed.path &
    (if parsed.query.len > 0: "?" & parsed.query else: "")
  let socket = newSocket()
  defer: socket.close()
  try:
    socket.connect(parsed.hostname, port, timeoutMs)
  except TimeoutError:
    raise newException(HttpMinError, "connect to " & parsed.hostname &
      " timed out after " & $timeoutMs & " ms")
  var request = verb & " " & target & " HTTP/1.1\r\nHost: " & parsed.hostname &
    "\r\nConnection: close\r\n"
  for (key, value) in headers:
    request.add(key & ": " & value & "\r\n")
  if body.len > 0:
    request.add("Content-Length: " & $body.len & "\r\n")
  request.add("\r\n")
  request.add(body)
  var writable = @[socket.getFd]
  if remainingMs(deadline) <= 0 or selectWrite(writable, remainingMs(deadline)) <= 0:
    raise newException(HttpMinError, "request to " & url &
      " timed out after " & $elapsedMs(started) & " ms")
  socket.send(request)
  var data = ""
  while true:
    let left = remainingMs(deadline)
    if left <= 0:
      raise newException(HttpMinError, "read from " & parsed.hostname &
        " timed out after " & $elapsedMs(started) & " ms")
    var readable = @[socket.getFd]
    let ready = selectRead(readable, left)
    if ready == 0:
      raise newException(HttpMinError, "read from " & parsed.hostname &
        " timed out after " & $elapsedMs(started) & " ms")
    if ready < 0:
      raise newException(HttpMinError, "read from " & parsed.hostname & " failed")
    let chunk = socket.recv(8192)
    if chunk.len == 0:
      break
    data.add(chunk)
  let separator = data.find("\r\n\r\n")
  if separator < 0:
    raise newException(HttpMinError, "malformed HTTP response")
  let head = data[0 ..< separator]
  let bodyText = data[separator + 4 .. ^1]
  let statusLine = head.split("\r\n")[0].split(' ')
  if statusLine.len < 2:
    raise newException(HttpMinError, "malformed status line")
  (parseInt(statusLine[1]), bodyText)
