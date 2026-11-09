## The shared library edges that no other suite owns: hex, the CLI contract every
## tool follows, and the minimal HTTP client the OIDC stub talks to. They are
## small files with real branches, and until this suite existed nothing imported
## them directly.
##
## The CLI contract is exercised through `cli_fixture.nim` below, not through an
## import: `fail`, `usageFail` and `flags` exit the process and read its command
## line, so only a child process can observe them.

import std/[monotimes, net, os, osproc, strutils, times, unittest]
import mummy
import ../hex
import ../http_min

proc fixtureBinary(): string =
  ## Builds the CLI fixture once, in a cache of its own, so a suite run cannot
  ## collide with the tree's build cache or with a parallel run.
  var built {.global.}: string
  if built.len > 0:
    return built
  let source = currentSourcePath().parentDir / "cli_fixture.nim"
  let directory = getTempDir() / ("majadu-cli-fixture-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "cli_fixture"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(source))
  if code != 0:
    raise newException(IOError, "cannot build the CLI fixture:\n" & output)
  built

proc run(args: string): (string, int) =
  execCmdEx(quoteShell(fixtureBinary()) & " " & args)

type
  StubArgs = object
    server: Server
    port: Port

proc serveStub(args: StubArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc answer(request: Request) {.gcsafe.} =
  request.respond(201, body = "ok")

proc freePort(): Port =
  ## The kernel picks an unused port. The probe socket is closed before the stub
  ## binds it, which is a smaller window than a hardcoded number that a suite
  ## running next to this one may already hold.
  let probe = newSocket()
  probe.setSockOpt(OptReuseAddr, true)
  probe.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = probe.getLocalAddr()
  probe.close()
  port

suite "hex":
  test "hexBytes round-trips bytesHex":
    let bytes = @[0x00'u8, 0x7f'u8, 0x80'u8, 0xff'u8]
    check hexBytes(bytesHex(bytes)) == bytes
    check bytesHex(bytes) == "007f80ff"

  test "upper case input is accepted and the output is always lower case":
    check hexBytes("00FF") == @[0x00'u8, 0xff'u8]
    check bytesHex(hexBytes("00FF")) == "00ff"
    check hexBytes("abcdef") == hexBytes("ABCDEF")

  test "an odd length is refused as ValueError":
    expect ValueError:
      discard hexBytes("abc")

  test "a non-hex pair is refused as ValueError":
    expect ValueError:
      discard hexBytes("zz")

suite "cli":
  test "fail exits 1 and writes the program and the message to stderr":
    let (output, code) = run("fail")
    check code == 1
    check output == "cli_fixture: the database said no\n"

  test "usageFail exits 2":
    let (output, code) = run("usage")
    check code == 2
    check output == "cli_fixture: unknown flag --nope\n"

  test "flags yields the value of a listed flag and an empty value otherwise":
    let (output, code) = run("flags --name budi --verbose")
    check code == 0
    check output == "--name=budi\n--verbose=\n"

  test "a listed flag at the end of the line is a usage failure":
    let (output, code) = run("flags --name")
    check code == 2
    check output == "cli_fixture: --name needs a value\n"

suite "http_min":
  test "an https url is refused before anything is connected":
    var message = ""
    try:
      discard httpRequest("https://id.test/token", "GET")
    except HttpMinError as error:
      message = error.msg
    check message.contains("only supports http")

  test "a url without a host is refused":
    var message = ""
    try:
      discard httpRequest("http://", "GET")
    except HttpMinError as error:
      message = error.msg
    check message.contains("missing host")

  test "a listener that accepts and never answers cannot block the client":
    ## SQ-09: a peer that completes the handshake and then stays silent used to
    ## hold the calling worker thread forever. The listen backlog accepts the
    ## connection, nothing reads it, and the read must give up on the bound.
    let listener = newSocket()
    defer: listener.close()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1]
    let started = getMonoTime()
    var message = ""
    try:
      discard httpRequest("http://127.0.0.1:" & $port.int & "/jwks", "GET",
        timeoutMs = 250)
    except HttpMinError as error:
      message = error.msg
    check message.contains("timed out")
    check (getMonoTime() - started).inMilliseconds < 5000

  test "the status and the body come back from a local listener":
    ## The stub is mummy, the same server `apps/api/tests/http_support.nim`
    ## runs: a raw `net` listener in this tree does not deliver bytes to a
    ## `net` client in this environment, and the unit under test is the client,
    ## not the server.
    let port = freePort()
    let stub = newServer(answer, workerThreads = 1)
    var worker: Thread[StubArgs]
    createThread(worker, serveStub, StubArgs(server: stub, port: port))
    var ready = false
    for _ in 0 ..< 50:
      try:
        let probe = newSocket()
        probe.connect("127.0.0.1", port)
        probe.close()
        ready = true
        break
      except CatchableError:
        sleep(100)
    check ready
    let (status, body) = httpRequest("http://127.0.0.1:" & $port.int &
      "/probe?x=1", "GET")
    stub.close()
    joinThread(worker)
    check status == 201
    check body == "ok"