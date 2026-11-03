import std/[net, strutils, uri]

type HttpMinError* = object of CatchableError

proc httpRequest*(url, verb: string, body = "",
                  headers: openArray[(string, string)] = []): (int, string) =
  ## Minimal HTTP/1.1 client for plain http (tests, OIDC stub). HTTPS goes
  ## through std/httpclient when the binary is built with -d:ssl.
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
  socket.connect(parsed.hostname, port)
  var request = verb & " " & target & " HTTP/1.1\r\nHost: " & parsed.hostname &
    "\r\nConnection: close\r\n"
  for (key, value) in headers:
    request.add(key & ": " & value & "\r\n")
  if body.len > 0:
    request.add("Content-Length: " & $body.len & "\r\n")
  request.add("\r\n")
  request.add(body)
  socket.send(request)
  var data = ""
  while true:
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
