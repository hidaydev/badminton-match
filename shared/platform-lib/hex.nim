import std/strutils

proc hexBytes*(value: string): seq[byte] =
  ## Lowercase or uppercase hex to bytes. Odd length is a programming error.
  if value.len mod 2 != 0:
    raise newException(ValueError, "odd hex length")
  result = newSeq[byte](value.len div 2)
  for index in 0 ..< result.len:
    result[index] = byte(parseHexInt(value[index * 2 .. index * 2 + 1]))

proc bytesHex*(value: openArray[byte]): string =
  result = newStringOfCap(value.len * 2)
  for byteValue in value:
    result.add(toHex(byteValue, 2).toLowerAscii())
