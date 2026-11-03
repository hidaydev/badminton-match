import std/[atomics, cpuinfo, os, posix]
import mummy
import build_info
import server

var shutdownRequested {.global.}: Atomic[bool]

proc onSignal(sig: cint) {.noconv.} =
  shutdownRequested.store(true, moRelaxed)

type
  ShutdownArgs = object
    server: Server
    drainMs: int
    timeoutMs: int

proc shutdownWatcher(args: ShutdownArgs) {.thread.} =
  while not shutdownRequested.load(moRelaxed):
    sleep(50)
  # Let in-flight requests finish before the listening socket goes away.
  sleep(args.drainMs)
  args.server.close()
  # Hard bound: if close() cannot finish, do not hang forever.
  sleep(args.timeoutMs)
  echo """{"level":"error","msg":"shutdown timed out"}"""
  quit(1)

proc main() =
  let config = loadConfig()
  let threads = max(countProcessors(), 2)
  let apiServer = newApiServer(config, threads)

  signal(SIGTERM, onSignal)
  signal(SIGINT, onSignal)

  var watcher: Thread[ShutdownArgs]
  createThread(
    watcher,
    shutdownWatcher,
    ShutdownArgs(
      server: apiServer,
      drainMs: config.drainMs,
      timeoutMs: config.shutdownTimeoutMs,
    ),
  )

  echo """{"level":"info","msg":"listening","port":""" & $config.port.int &
    ""","build":""" & buildInfoJson(threads) & "}"
  try:
    apiServer.serve(config.port, "0.0.0.0")
  except MummyError as error:
    var detail = ""
    for c in error.msg:
      case c
      of '"': detail.add("\\\"")
      of '\\': detail.add("\\\\")
      of '\n': detail.add("\\n")
      else: detail.add(c)
    stderr.writeLine("{\"level\":\"error\",\"msg\":\"serve failed\",\"detail\":\"" &
      detail & "\"}")
    quit(1)

  # serve() returns once close() finishes draining. Exit without joining the
  # watcher: it is intentionally parked on the hard-timeout sleep.
  quit(0)

when isMainModule:
  main()
