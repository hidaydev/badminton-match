import std/[strutils, sysrand]

proc newToken*(): string =
  ## Opaque bearer value handed to the caller once. Only its hash is stored.
  var bytes = newSeq[byte](32)
  if not urandom(bytes):
    raise newException(IOError, "no entropy available")
  for byte in bytes:
    result.add(toHex(byte, 2).toLowerAscii())
