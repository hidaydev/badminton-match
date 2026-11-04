import std/unittest
import ../src/live

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
