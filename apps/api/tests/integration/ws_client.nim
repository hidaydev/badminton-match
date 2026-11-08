## Minimal RFC 6455 client for tests. Nim 2.4 no longer ships a websocket client,
## and this only needs the handshake plus single unfragmented text frames.
##
## Every read takes a timeout: a case that expects a frame fails with
## `TimeoutError` instead of hanging the suite, and no case sleeps to wait for
## one. The helper also owns the opening sequence every suite repeats (wait for
## `ready`, then subscribe) and the reconnect that resumes at `lastSeq`.
import std/[net, strutils]

type
  WsError* = object of CatchableError
  WsClosed* = object of WsError

  WsClient* = ref object
    socket: Socket
    status*: int
    sent*: seq[string]

const
  defaultTimeoutMs* = 5_000

proc recvExactly(socket: Socket, size, timeout: int): string =
  result = ""
  while result.len < size:
    let chunk = socket.recv(size - result.len, timeout)
    if chunk.len == 0:
      raise newException(WsClosed, "connection closed")
    result.add(chunk)

proc connectWs*(host: string, port: int, path: string): WsClient =
  let socket = newSocket()
  socket.connect(host, Port(port))
  socket.send("GET " & path & " HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n")
  var head = ""
  while not head.endsWith("\r\n\r\n"):
    head.add(recvExactly(socket, 1, defaultTimeoutMs))
  let statusLine = head.split("\r\n")[0].split(' ')
  if statusLine.len < 2:
    raise newException(WsError, "bad handshake: " & head)
  result = WsClient(socket: socket, status: parseInt(statusLine[1]))
  if result.status != 101:
    socket.close()

proc sendText*(client: WsClient, text: string) =
  var frame = ""
  frame.add(char(0x81))
  if text.len < 126:
    frame.add(char(0x80 or text.len))
  elif text.len < 65536:
    frame.add(char(0x80 or 126))
    frame.add(char((text.len shr 8) and 0xff))
    frame.add(char(text.len and 0xff))
  else:
    frame.add(char(0x80 or 127))
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      frame.add(char((text.len shr shift) and 0xff))
  let mask = [0x11, 0x22, 0x33, 0x44]
  for value in mask:
    frame.add(char(value))
  for index, value in text:
    frame.add(char(uint8(ord(value)) xor uint8(mask[index mod 4])))
  client.sent.add(text)
  client.socket.send(frame)

proc receiveText*(client: WsClient, timeout = defaultTimeoutMs): string =
  let header = recvExactly(client.socket, 2, timeout)
  let opcode = ord(header[0]) and 0x0f
  var length = ord(header[1]) and 0x7f
  if length == 126:
    let extended = recvExactly(client.socket, 2, timeout)
    length = (ord(extended[0]) shl 8) or ord(extended[1])
  elif length == 127:
    let extended = recvExactly(client.socket, 8, timeout)
    length = 0
    for index in 0 ..< 8:
      length = (length shl 8) or ord(extended[index])
  let masked = (ord(header[1]) and 0x80) != 0
  var mask = ""
  if masked:
    mask = recvExactly(client.socket, 4, timeout)
  var payload = recvExactly(client.socket, length, timeout)
  if masked:
    for index in 0 ..< payload.len:
      payload[index] = char(ord(payload[index]) xor ord(mask[index mod 4]))
  if opcode == 0x8:
    raise newException(WsClosed, "closed by the server")
  payload

proc closeWs*(client: WsClient) =
  client.socket.close()

proc awaitReady*(client: WsClient): string =
  ## The upgrade handler sends `ready` before any other frame.
  result = client.receiveText()
  if result != """{"type":"ready"}""":
    raise newException(WsError, "expected ready, got: " & result)

proc openWs*(host: string, port: int, path: string): WsClient =
  ## Handshake plus the first frame, so a caller that gets a client knows the
  ## channel was admitted instead of guessing from a byte count.
  result = connectWs(host, port, path)
  if result.status != 101:
    raise newException(WsError, "handshake returned " & $result.status)
  discard result.awaitReady()

proc subscribe*(client: WsClient, lastSeq: int) =
  client.sendText("""{"type":"subscribe","lastSeq":""" & $lastSeq & "}")

proc reconnect*(client: WsClient, host: string, port: int, path: string,
                lastSeq: int): WsClient =
  ## Drops the stale socket and opens a fresh one at `lastSeq`, the sequence the
  ## caller last saw. The server has no replay log today, but the frame must
  ## still be sent so a client that resumes is not silently a fresh reader.
  closeWs(client)
  result = openWs(host, port, path)
  result.subscribe(lastSeq)