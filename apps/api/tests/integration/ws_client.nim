## Minimal RFC 6455 client for tests. Nim 2.4 no longer ships a websocket client,
## and this only needs the handshake plus single unfragmented text frames.
import std/[net, strutils]

type
  WsError* = object of CatchableError
  WsClosed* = object of WsError

  WsClient* = ref object
    socket: Socket
    status*: int

proc recvExactly(socket: Socket, size: int): string =
  result = ""
  while result.len < size:
    let chunk = socket.recv(size - result.len)
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
    head.add(recvExactly(socket, 1))
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
  client.socket.send(frame)

proc receiveText*(client: WsClient): string =
  let header = recvExactly(client.socket, 2)
  let opcode = ord(header[0]) and 0x0f
  var length = ord(header[1]) and 0x7f
  if length == 126:
    let extended = recvExactly(client.socket, 2)
    length = (ord(extended[0]) shl 8) or ord(extended[1])
  elif length == 127:
    let extended = recvExactly(client.socket, 8)
    length = 0
    for index in 0 ..< 8:
      length = (length shl 8) or ord(extended[index])
  let masked = (ord(header[1]) and 0x80) != 0
  var mask = ""
  if masked:
    mask = recvExactly(client.socket, 4)
  var payload = recvExactly(client.socket, length)
  if masked:
    for index in 0 ..< payload.len:
      payload[index] = char(ord(payload[index]) xor ord(mask[index mod 4]))
  if opcode == 0x8:
    raise newException(WsClosed, "closed by the server")
  payload

proc closeWs*(client: WsClient) =
  client.socket.close()
