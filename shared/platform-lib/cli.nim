## The contract every program under `tools/` follows: one place decides how a
## failure is spelled and which exit code it carries, so a script can tell
## "the tool ran and the work failed" from "the command line was wrong".
##
##   1  runtime failure: the line parsed, the work could not be done
##   2  usage failure: the line itself is wrong

import std/os

proc fail*(program, message: string) {.noreturn.} =
  ## The arguments were understood; the work could not be carried out. That
  ## covers a missing variable, an unusable value and a database that says no.
  stderr.writeLine program & ": " & message
  quit(1)

proc usageFail*(program, message: string) {.noreturn.} =
  ## The line itself is wrong: an unknown command or flag, a required flag that
  ## was not given, a flag left without its value.
  stderr.writeLine program & ": " & message
  quit(2)

proc dsnOrFail*(program: string, name = "MAJADU_PG_DSN", detail = ""): string =
  ## The connection string from `name`. `detail` replaces the default complaint
  ## when a flag could have supplied the value instead.
  result = getEnv(name)
  if result.len == 0:
    fail(program, if detail.len > 0: detail else: name & " is required")

proc valueOf*(program, flag: string, index: var int): string =
  ## Consumes the value that follows `flag`. A flag left at the end of the line
  ## is a usage failure, not the IndexDefect a bare paramStr would raise.
  inc index
  if index > paramCount():
    usageFail(program, flag & " needs a value")
  paramStr(index)

iterator flags*(program: string, start: int, valued: openArray[string]):
    tuple[flag, value: string] =
  ## Walks the command line from `start`, yielding each flag with the value that
  ## follows it. A flag outside `valued` takes no value and yields "".
  var index = start
  while index <= paramCount():
    let flag = paramStr(index)
    if flag in valued:
      yield (flag, valueOf(program, flag, index))
    else:
      yield (flag, "")
    inc index