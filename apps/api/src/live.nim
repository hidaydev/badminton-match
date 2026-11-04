import std/[json, locks, tables]
import mummy
import db/db
import ws_ticket

type
  WatcherCaps* = object
    ## Copied from the config snapshot per upgrade, never hardcoded.
    perSession*: int
    perIp*: int
    process*: int

  AdmitDecision* = enum
    admitAllowed
    admitFull

  SocketEntry = object
    ws: WebSocket
    channel: string
    userId: string
    ip: string

  LiveHub* = ref object
    ## Single-instance fan-out. Mummy hands the websocket handler no request, so
    ## the HTTP upgrade registers the socket here and events find it by value.
    db*: Db
    lock: Lock
    sockets: seq[SocketEntry]
    perChannel: Table[string, int]
    perIp: Table[string, int]

const
  readyFrame* = """{"type":"ready"}"""
  fullFrame* = """{"type":"full"}"""
  pongFrame* = """{"type":"pong"}"""
  revokedFrame* = """{"type":"revoked"}"""

var installed {.global.}: LiveHub

proc installHub*(hub: LiveHub) =
  ## Called once at boot, before `newServer`, so no event can arrive first.
  installed = hub

proc channelSession*(sessionId: string): string = "session:" & sessionId
proc channelShare*(linkId: string): string = "share:" & linkId

proc newHub*(db: Db): LiveHub =
  result = LiveHub(db: db)
  initLock(result.lock)
  result.perChannel = initTable[string, int]()
  result.perIp = initTable[string, int]()

proc decideAdmit*(caps: WatcherCaps, sessionWatchers, ipWatchers,
                  processWatchers: int): AdmitDecision =
  ## Pure threshold arithmetic, so the caps are testable without sockets. The
  ## Nth watcher is admitted, the N+1th is not.
  if sessionWatchers >= caps.perSession:
    return admitFull
  if ipWatchers >= caps.perIp:
    return admitFull
  if processWatchers >= caps.process:
    return admitFull
  admitAllowed

proc socketIndex(hub: LiveHub, ws: WebSocket): int =
  ## WebSocket has no exported identity fields, so entries are matched by value.
  ## The table holds at most `ws.max_watchers_process` entries.
  for index in 0 ..< hub.sockets.len:
    if hub.sockets[index].ws == ws:
      return index
  -1

proc forget(hub: LiveHub, index: int) =
  let entry = hub.sockets[index]
  hub.sockets.delete(index)
  let channelCount = hub.perChannel.getOrDefault(entry.channel) - 1
  if channelCount <= 0:
    hub.perChannel.del(entry.channel)
  else:
    hub.perChannel[entry.channel] = channelCount
  let ipCount = hub.perIp.getOrDefault(entry.ip) - 1
  if ipCount <= 0:
    hub.perIp.del(entry.ip)
  else:
    hub.perIp[entry.ip] = ipCount

proc admit*(hub: LiveHub, ws: WebSocket, channel, userId, ip: string,
            caps: WatcherCaps): bool =
  ## Reserves a slot before the first frame is sent. Returns false when any cap
  ## is already reached; the caller answers `full` and closes.
  acquire(hub.lock)
  try:
    let decision = decideAdmit(caps, hub.perChannel.getOrDefault(channel),
      hub.perIp.getOrDefault(ip), hub.sockets.len)
    if decision == admitFull:
      return false
    hub.sockets.add(SocketEntry(ws: ws, channel: channel, userId: userId, ip: ip))
    hub.perChannel[channel] = hub.perChannel.getOrDefault(channel) + 1
    hub.perIp[ip] = hub.perIp.getOrDefault(ip) + 1
    true
  finally:
    release(hub.lock)

proc release*(hub: LiveHub, ws: WebSocket) =
  acquire(hub.lock)
  try:
    let index = hub.socketIndex(ws)
    if index >= 0:
      hub.forget(index)
  finally:
    release(hub.lock)

proc closeWhere(hub: LiveHub, match: proc(entry: SocketEntry): bool {.closure.},
                frame: string) =
  var doomed: seq[WebSocket] = @[]
  acquire(hub.lock)
  try:
    if match != nil:
      for index in countdown(hub.sockets.len - 1, 0):
        if match(hub.sockets[index]):
          doomed.add(hub.sockets[index].ws)
          hub.forget(index)
  finally:
    release(hub.lock)
  for ws in doomed:
    if frame.len > 0:
      ws.send(frame)
    ws.close()

proc broadcast*(hub: LiveHub, channel, frame: string) =
  var targets: seq[WebSocket] = @[]
  acquire(hub.lock)
  try:
    for entry in hub.sockets:
      if entry.channel == channel:
        targets.add(entry.ws)
  finally:
    release(hub.lock)
  for ws in targets:
    ws.send(frame)

proc sessionChanged*(hub: LiveHub, sessionId: string, seq: int) =
  ## `seq` only lets a client detect a gap; it is not a replay log.
  hub.broadcast(channelSession(sessionId),
    """{"type":"session.changed","seq":""" & $seq & "}")

proc revokePrincipal*(hub: LiveHub, userId: string) =
  ## Logout and revoke-other-sessions call this today. Role change, member
  ## removal and demo promotion do not have routes yet; when they land they call
  ## the same helper instead of building a channel-specific variant.
  if userId.len == 0:
    return
  discard ws_ticket.revokePrincipal(hub.db, userId)
  hub.closeWhere(proc(entry: SocketEntry): bool = entry.userId == userId,
    revokedFrame)

proc revokeShare*(hub: LiveHub, linkId: string) =
  ## A rotated or deleted link closes its watchers and drops their tickets.
  if linkId.len == 0:
    return
  discard ws_ticket.revokeShare(hub.db, linkId)
  let channel = channelShare(linkId)
  hub.closeWhere(proc(entry: SocketEntry): bool = entry.channel == channel,
    revokedFrame)

proc dispatch*(hub: LiveHub, ws: WebSocket, event: WebSocketEvent,
               message: Message) =
  case event
  of OpenEvent:
    discard # `ready` is sent by the upgrade handler, before Open can arrive.
  of CloseEvent, ErrorEvent:
    hub.release(ws)
  of MessageEvent:
    var accepted = false
    if message.kind == TextMessage:
      var frame: JsonNode
      try:
        frame = parseJson(message.data)
      except JsonParsingError:
        frame = newJNull()
      if frame.kind == JObject and frame.hasKey("type") and
         frame["type"].kind == JString:
        case frame["type"].getStr()
        of "ping":
          ws.send(pongFrame)
          accepted = true
        of "subscribe":
          # `lastSeq` is read and discarded: no replay, no channel state.
          accepted = frame.hasKey("lastSeq")
        else:
          discard
    if not accepted:
      hub.release(ws)
      ws.close()

proc websocketHandler*(): WebSocketHandler =
  ## Mummy calls this from worker threads for every event of every socket.
  result = proc(websocket: WebSocket, event: WebSocketEvent,
                message: Message) {.gcsafe.} =
    {.cast(gcsafe).}:
      let hub = installed
      if hub != nil:
        hub.dispatch(websocket, event, message)
