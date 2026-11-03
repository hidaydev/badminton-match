import std/strutils
import nimcrypto

proc sha256Hex*(data: string): string =
  ## Lowercase hex SHA-256, used for token hashes and contract fingerprints.
  toLowerAscii($nimcrypto.sha256.digest(data))

proc sha256Raw*(data: string): array[32, byte] =
  let digest = nimcrypto.sha256.digest(data)
  for index in 0 ..< 32:
    result[index] = digest.data[index]
