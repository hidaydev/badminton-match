import std/unittest
import mummy
import db/db
import ../src/live

proc fakeSocket(id: int): WebSocket =
  ## `WebSocket` has no public constructor and the hub only stores and compares
  ## it, so a suite builds distinct values from raw bytes. Nothing in these
  ## tests sends, closes or otherwise dereferences one.
  var raw: array[sizeof(WebSocket), byte]
  copyMem(raw[0].addr, unsafeAddr id, min(sizeof(int), sizeof(WebSocket)))
  cast[WebSocket](raw)

suite "watcher caps":
  let caps = WatcherCaps(perSession: 50, perIp: 20, process: 500)

  test "the 50th watcher is admitted and the 51st is full":
    check decideAdmit(caps, 49, 0, 0) == admitAllowed
    check decideAdmit(caps, 50, 0, 0) == admitFull
    check decideAdmit(caps, 51, 0, 0) == admitFull

  test "per-address cap is independent of the session cap":
    check decideAdmit(caps, 0, 19, 0) == admitAllowed
    check decideAdmit(caps, 0, 20, 0) == admitFull
    check decideAdmit(caps, 1, 20, 0) == admitFull

  test "per-process cap covers every channel":
    check decideAdmit(caps, 0, 0, 499) == admitAllowed
    check decideAdmit(caps, 0, 0, 500) == admitFull

  test "a cap of one admits a single watcher":
    let single = WatcherCaps(perSession: 1, perIp: 1, process: 1)
    check decideAdmit(single, 0, 0, 0) == admitAllowed
    check decideAdmit(single, 1, 0, 0) == admitFull

suite "hub frames and channels":
  test "frames match the frozen protocol":
    check readyFrame == """{"type":"ready"}"""
    check fullFrame == """{"type":"full"}"""
    check pongFrame == """{"type":"pong"}"""
    check revokedFrame == """{"type":"revoked"}"""

  test "channels carry the row id, never a slug or a code":
    check channelSession("0193f0e2-0000-7000-8000-000000000001") ==
      "session:0193f0e2-0000-7000-8000-000000000001"
    check channelShare("0193f0e2-0000-7000-8000-000000000002") ==
      "share:0193f0e2-0000-7000-8000-000000000002"

suite "socket registry":
  let caps = WatcherCaps(perSession: 100, perIp: 100_000, process: 600)

  test "a disconnect touches one channel bucket, not the registry":
    # BE-24: 500 sockets over 200 channels. A release that walked the registry
    # would bump `channelVisits` by 500 instead of 1, so this is the counter
    # that proves the index is used.
    let hub = newHub(Db())
    var admitted = 0
    for id in 0 ..< 500:
      if hub.admit(fakeSocket(id), "session:" & $(id mod 200),
          "user-" & $(id mod 7), "ip-" & $(id mod 13), caps):
        inc admitted
    check admitted == 500
    check hub.stats.sockets == 500
    check hub.stats.channels == 200
    let before = hub.stats.channelVisits
    hub.release(fakeSocket(0))
    check hub.stats.sockets == 499
    check hub.stats.channelVisits == before + 1
    # The other 199 channels keep their watchers untouched.
    check hub.watchers("session:1").len == 3
    check hub.watchers("session:0").len == 2

  test "a second release of the same socket changes nothing":
    let hub = newHub(Db())
    discard hub.admit(fakeSocket(1), "session:a", "user-a", "ip-a", caps)
    hub.release(fakeSocket(1))
    let once = hub.stats
    hub.release(fakeSocket(1))
    let twice = hub.stats
    check twice.sockets == once.sockets
    check twice.users == once.users
    check twice.ips == once.ips
    check twice.channelVisits == once.channelVisits
    check hub.watchers("session:a").len == 0

  test "the per-session cap counts its own channel, not every watcher":
    let hub = newHub(Db())
    let single = WatcherCaps(perSession: 2, perIp: 100, process: 600)
    check hub.admit(fakeSocket(1), "session:a", "", "ip-a", single)
    check hub.admit(fakeSocket(2), "session:b", "", "ip-a", single)
    check hub.admit(fakeSocket(3), "session:a", "", "ip-a", single)
    # `session:a` is full even though the process holds only three watchers.
    check not hub.admit(fakeSocket(4), "session:a", "", "ip-b", single)
    check hub.watchers("session:a").len == 2
    check hub.watchers("session:b").len == 1

  test "a broadcast target list is only its own channel":
    let hub = newHub(Db())
    for id in 0 ..< 200:
      discard hub.admit(fakeSocket(id), "session:" & $(id mod 100),
        "user-" & $(id mod 5), "ip-" & $(id mod 11), caps)
    check hub.watchers("session:7").len == 2
    check hub.watchers("session:99").len == 2
    check hub.watchers("session:100").len == 0

suite "queued-frame bound":
  ## REL-BE-07: a watcher that stops reading must not grow mummy's outbound
  ## queue into the container's MemoryMax. `reserveFrame` is the decision, and it
  ## is pure arithmetic over the registry so it needs no handshake to test.
  let caps = WatcherCaps(perSession: 100, perIp: 100, process: 600)

  test "the Nth frame is accepted and the N+1th drops the socket":
    let hub = newHub(Db())
    discard hub.admit(fakeSocket(1), "session:a", "user-a", "ip-a", caps)
    for _ in 0 ..< maxQueuedFrames:
      check hub.reserveFrame(fakeSocket(1))
    check not hub.reserveFrame(fakeSocket(1))
    # The refused frame is also the disconnect: the socket leaves every index, so
    # the next broadcast does not even find it.
    check hub.stats.sockets == 0
    check hub.watchers("session:a").len == 0

  test "an inbound frame reopens the window":
    let hub = newHub(Db())
    discard hub.admit(fakeSocket(2), "session:b", "user-b", "ip-b", caps)
    for _ in 0 ..< maxQueuedFrames:
      check hub.reserveFrame(fakeSocket(2))
    check not hub.reserveFrame(fakeSocket(2))
    # `dispatch` proves reading before it answers a ping, so a board that keeps
    # pinging is never dropped for a queue it is draining.
    let fresh = newHub(Db())
    discard fresh.admit(fakeSocket(3), "session:c", "user-c", "ip-c", caps)
    for _ in 0 ..< maxQueuedFrames:
      check fresh.reserveFrame(fakeSocket(3))
    fresh.proofOfReading(fakeSocket(3))
    check fresh.reserveFrame(fakeSocket(3))
    check fresh.stats.sockets == 1

  test "one stuck socket never takes its neighbours with it":
    let hub = newHub(Db())
    for id in 0 ..< 3:
      discard hub.admit(fakeSocket(id), "session:d", "user-" & $id, "ip-" & $id,
        caps)
    for _ in 0 ..< maxQueuedFrames:
      check hub.reserveFrame(fakeSocket(0))
    check not hub.reserveFrame(fakeSocket(0))
    # The other two keep their slots and their empty windows.
    check hub.stats.sockets == 2
    check hub.reserveFrame(fakeSocket(1))
    check hub.reserveFrame(fakeSocket(2))

  test "a released socket is never counted back into the registry":
    ## A release can land between the target list and the write. Counting that
    ## socket would leak a counter entry and let a frame reach a closed socket.
    let hub = newHub(Db())
    discard hub.admit(fakeSocket(4), "session:e", "user-e", "ip-e", caps)
    hub.release(fakeSocket(4))
    check not hub.reserveFrame(fakeSocket(4))
    check hub.stats.sockets == 0
    check hub.watchers("session:e").len == 0
