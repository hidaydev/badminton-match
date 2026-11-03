import std/[strutils, sysrand, times]

proc uuidv7Bytes*(unixMs: int64): array[16, byte] =
  var randomBytes: array[16, byte]
  if not urandom(randomBytes):
    raise newException(OSError, "cannot read random bytes for uuidv7")
  let ms = uint64(unixMs)
  result[0] = byte((ms shr 40) and 0xff)
  result[1] = byte((ms shr 32) and 0xff)
  result[2] = byte((ms shr 24) and 0xff)
  result[3] = byte((ms shr 16) and 0xff)
  result[4] = byte((ms shr 8) and 0xff)
  result[5] = byte(ms and 0xff)
  for i in 6 .. 15:
    result[i] = randomBytes[i]
  result[6] = (result[6] and 0x0f) or 0x70
  result[8] = (result[8] and 0x3f) or 0x80

proc formatUuid*(bytes: array[16, byte]): string =
  for i, b in bytes:
    if i in {4, 6, 8, 10}:
      result.add('-')
    result.add(toHex(b, 2).toLowerAscii)

proc uuidv7*(unixMs: int64): string =
  formatUuid(uuidv7Bytes(unixMs))

proc uuidv7*(): string =
  uuidv7(int64(epochTime() * 1000.0))
