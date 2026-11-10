import std/[json, locks, sets, tables]
import mummy
import db/db
import platform/ws_ticket

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

  RegistryStats* = object
    ## Sizes plus the number of channel buckets the hub had to touch. A full
    ## registry scan would raise `channelVisits` by the socket count, so a suite
    ## reads it to prove a disconnect stays proportional to one channel.
    sockets*: int
    channels*: int
    users*: int
    ips*: int
    channelVisits*: int

  LiveHub* = ref object
    ## Single-instance fan-out. Mummy hands the websocket handler no request, so
    ## the HTTP upgrade registers the socket here and events find it by value.
    ## Indexed both ways: an entry per socket, and buckets per channel and per
    ## principal, so admit, release and broadcast never walk the registry.
    db*: Db
    lock: Lock
    entries: Table[WebSocket, SocketEntry]
    byChannel: Table[string, seq[WebSocket]]
    byUser: Table[string, HashSet[WebSocket]]
    byIp: Table[string, int]
    channelVisits: int

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
  result.entries = initTable[WebSocket, SocketEntry]()
  result.byChannel = initTable[string, seq[WebSocket]]()
  result.byUser = initTable[string, HashSet[WebSocket]]()
  result.byIp = initTable[string, int]()

proc stats*(hub: LiveHub): RegistryStats =
  ## Taken under the lock so a suite never reads a half-updated index.
  acquire(hub.lock)
  try:
    RegistryStats(sockets: hub.entries.len, channels: hub.byChannel.len,
      users: hub.byUser.len, ips: hub.byIp.len,
      channelVisits: hub.channelVisits)
  finally:
    release(hub.lock)

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

proc watchers*(hub: LiveHub, channel: string): seq[WebSocket] =
  ## The sockets on one channel. `broadcast` sends to this list outside the lock,
  ## so the registry is never held while a client is written to.
  acquire(hub.lock)
  try:
    result = hub.byChannel.getOrDefault(channel)
  finally:
    release(hub.lock)

proc forget(hub: LiveHub, ws: WebSocket) =
  ## Drops one socket from every index it appears in. `channelVisits` counts the
  ## one channel bucket it touches: a registry-wide scan would count every
  ## socket instead.
  if not hub.entries.hasKey(ws):
    return
  let entry = hub.entries[ws]
  hub.entries.del(ws)
  inc hub.channelVisits
  if hub.byChannel.hasKey(entry.channel):
    let at = hub.byChannel[entry.channel].find(ws)
    if at >= 0:
      hub.byChannel[entry.channel].delete(at)
    if hub.byChannel[entry.channel].len == 0:
      hub.byChannel.del(entry.channel)
  if entry.userId.len > 0:
    hub.byUser[entry.userId].excl(ws)
    if hub.byUser[entry.userId].len == 0:
      hub.byUser.del(entry.userId)
  let remaining = hub.byIp.getOrDefault(entry.ip) - 1
  if remaining <= 0:
    hub.byIp.del(entry.ip)
  else:
    hub.byIp[entry.ip] = remaining

proc admit*(hub: LiveHub, ws: WebSocket, channel, userId, ip: string,
            caps: WatcherCaps): bool =
  ## Reserves a slot before the first frame is sent. Returns false when any cap
  ## is already reached; the caller answers `full` and closes.
  acquire(hub.lock)
  try:
    let decision = decideAdmit(caps, hub.byChannel.getOrDefault(channel).len,
      hub.byIp.getOrDefault(ip), hub.entries.len)
    if decision == admitFull:
      return false
    hub.entries[ws] = SocketEntry(ws: ws, channel: channel, userId: userId,
      ip: ip)
    hub.byChannel.mgetOrPut(channel, @[]).add(ws)
    if userId.len > 0:
      hub.byUser.mgetOrPut(userId, initHashSet[WebSocket]()).incl(ws)
    hub.byIp[ip] = hub.byIp.getOrDefault(ip) + 1
    inc hub.channelVisits
    true
  finally:
    release(hub.lock)

proc release*(hub: LiveHub, ws: WebSocket) =
  acquire(hub.lock)
  try:
    hub.forget(ws)
  finally:
    release(hub.lock)

proc closeSockets(doomed: seq[WebSocket], frame: string) =
  for ws in doomed:
    if frame.len > 0:
      ws.send(frame)
    ws.close()

proc closeChannel(hub: LiveHub, channel, frame: string) =
  let doomed = hub.watchers(channel)
  acquire(hub.lock)
  try:
    for ws in doomed:
      hub.forget(ws)
  finally:
    release(hub.lock)
  closeSockets(doomed, frame)

proc closeUser(hub: LiveHub, userId, frame: string) =
  var doomed: seq[WebSocket] = @[]
  acquire(hub.lock)
  try:
    for ws in hub.byUser.getOrDefault(userId):
      doomed.add(ws)
    for ws in doomed:
      hub.forget(ws)
  finally:
    release(hub.lock)
  closeSockets(doomed, frame)

proc broadcast*(hub: LiveHub, channel, frame: string) =
  let targets = hub.watchers(channel)
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
  hub.closeUser(userId, revokedFrame)

proc revokeShare*(hub: LiveHub, linkId: string) =
  ## A rotated or deleted link closes its watchers and drops their tickets.
  if linkId.len == 0:
    return
  discard ws_ticket.revokeShare(hub.db, linkId)
  hub.closeChannel(channelShare(linkId), revokedFrame)

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
