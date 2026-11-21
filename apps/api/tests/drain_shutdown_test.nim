# REL-QA-04: the unit files give the container `StopTimeout=40`, which is only
# useful if the process actually drains inside that window. `main` arms a
# SIGTERM handler, lets in-flight requests finish for `MAJADU_DRAIN_MS`, then
# closes the socket; nothing proved it, so podman's default 10 s kill and the
# 5 s + 30 s budget could disagree without a test noticing.
#
# The proof is a real process: this suite builds the API, starts it with
# `MAJADU_TEST_ROUTES=1` (the stub router needs no database, so this runs
# anywhere), fires the slow route, sends SIGTERM mid-request, and checks the
# process left on its own terms.
import std/[monotimes, net, os, osproc, streams, strutils, times, unittest]

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  ## Long enough for the 700 ms slow route to still be in flight when the
  ## signal lands, short enough that a hung process fails the suite instead of
  ## the job.
  drainMs = 1500
  shutdownTimeoutMs = 5000
  ## The slow route sleeps 700 ms; past this the request had already finished
  ## and the test would prove nothing about draining.
  slowRouteMs = 700

proc freePort(): int =
  ## Bind port 0 and read back what the OS chose. A fixed port collides with a
  ## leftover process on a developer machine, which is the failure mode this
  ## suite is about.
  var socket = newSocket()
  defer: socket.close()
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(Port(0), "127.0.0.1")
  int(socket.getLocalAddr()[1])

proc buildApi(workDir: string): string =
  ## A debug build on purpose: `-d:release` compiles `MAJADU_TEST_ROUTES` out,
  ## so the stub router that needs no database would not exist.
  let binary = workDir / "majadu-api"
  let build = startProcess("nim", args = @[
      "c", "--hints:off", "--nimcache:" & workDir / "nimcache",
      "-o:" & binary, repoRoot / "apps" / "api" / "src" / "main.nim"],
    workingDir = repoRoot, options = {poUsePath})
  let log = build.outputStream.readAll() & build.errorStream.readAll()
  let code = build.waitForExit()
  build.close()
  if code != 0 or not fileExists(binary):
    raise newException(IOError, "api build failed:\n" & log)
  binary

proc startApi(binary, workDir, logPath, port: string): Process =
  ## `exec` replaces the shell, so the pid this process reports is the API's
  ## own: a signal sent here reaches the handler under test, not a wrapper.
  let command = "MAJADU_PORT=" & port &
    " MAJADU_DRAIN_MS=" & $drainMs &
    " MAJADU_SHUTDOWN_TIMEOUT_MS=" & $shutdownTimeoutMs &
    " MAJADU_ENV=dev MAJADU_TEST_ROUTES=1 exec " & quoteShell(binary) &
    " >" & quoteShell(logPath) & " 2>&1"
  startProcess("sh", args = @["-c", command], workingDir = workDir,
    options = {poUsePath})

proc waitForHealthz(process: Process, port: string, logPath: string): bool =
  ## A readiness wait with its own ceiling: a process that never listens must
  ## fail this suite, not sit until the job's fifteen minutes run out.
  let deadline = getMonoTime() + initDuration(seconds = 15)
  while getMonoTime() < deadline:
    if not process.running:
      return false
    try:
      var socket = newSocket()
      defer: socket.close()
      socket.connect("127.0.0.1", Port(parseInt(port)))
      socket.send("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
      let answer = socket.recvLine(timeout = 1000)
      if "200" in answer:
        return true
    except CatchableError:
      discard
    sleep(50)
  discard logPath
  false

suite "shutdown drain":
  test "SIGTERM mid-request finishes it and exits 0 inside the drain bound":
    let workDir = getTempDir() / "majadu-drain-" & $getCurrentProcessId()
    createDir(workDir)
    defer: removeDir(workDir)
    let binary = buildApi(workDir)
    let port = $freePort()
    let logPath = workDir / "api.log"

    let process = startApi(binary, workDir, logPath, port)
    defer:
      if process.running:
        process.kill()
      process.close()

    # A failed readiness is a failure of this case, not a skip: `check` on a
    # real condition keeps it inside R-02's rules, and the message carries the
    # log so a red run names why.
    let healthy = process.running and waitForHealthz(process, port, logPath)
    if not healthy:
      checkpoint("api log: " &
        (if fileExists(logPath): readFile(logPath) else: "<none>"))
    check healthy

    # The client runs beside the signal: the point is a request still open when
    # the stop arrives, which is exactly what a podman stop does to a real user.
    let client = startProcess("sh", args = @["-c",
      "sleep 0.25; curl -s -m 10 -o " & quoteShell(workDir / "slow.out") &
        " -w '%{http_code}' " & "http://127.0.0.1:" & port & "/__test/slow"],
      workingDir = workDir, options = {poUsePath})
    defer: client.close()

    sleep(100)
    let started = getMonoTime()
    process.terminate() # SIGTERM, the same signal a container stop sends
    let exitCode = process.waitForExit()
    let elapsedMs = (getMonoTime() - started).inMilliseconds
    let httpCode = client.outputStream.readAll().strip()
    check client.waitForExit() == 0

    # A SIGKILL is 137 and a SIGTERM that never reached the handler is 143.
    # Only a process that shut itself down reports 0.
    check exitCode == 0
    # The request that was open when the signal landed got its answer: the
    # write the drain exists to protect is not lost.
    check httpCode == "200"
    check fileExists(workDir / "slow.out")
    # It waited for that request (>= the 700 ms route) but did not sit on the
    # hard bound: a process that ignored SIGTERM would be killed at 143.
    check elapsedMs >= slowRouteMs
    check elapsedMs < drainMs + shutdownTimeoutMs
