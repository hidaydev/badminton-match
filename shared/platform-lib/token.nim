## Opaque bearer values: one generator, so a change to its strength or its
## encoding lands in one place instead of three copies that only look alike.

import std/[strutils, sysrand]

proc newOpaqueToken*(): string =
  ## 32 random bytes as lowercase hex. The caller hands the value out once and
  ## stores only its hash, so a database dump cannot be replayed.
  var bytes: array[32, byte]
  if not urandom(bytes):
    raise newException(IOError, "no entropy available")
  for value in bytes:
    result.add(toHex(value, 2).toLowerAscii())