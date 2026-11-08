## Opaque bearer values: one generator, so a change to its strength or its
## encoding lands in one place instead of three copies that only look alike.

import std/[strutils, sysrand]

type
  ByteSource* = proc(count: int): seq[byte] {.closure.}
    ## The one test seam in this item (D-5). Production keeps the default and
    ## every call site stays where it is; a test passes a source it controls so
    ## the exact output can be asserted instead of only its length.

proc randomBytes*(count: int): seq[byte] =
  result = newSeq[byte](count)
  if not urandom(result):
    raise newException(IOError, "no entropy available")

proc newOpaqueToken*(source: ByteSource = nil): string =
  ## 32 random bytes as lowercase hex. The caller hands the value out once and
  ## stores only its hash, so a database dump cannot be replayed. Without a
  ## source the bytes come from the operating system, as they always have.
  let bytes = if source.isNil: randomBytes(32) else: source(32)
  for value in bytes:
    result.add(toHex(value, 2).toLowerAscii())