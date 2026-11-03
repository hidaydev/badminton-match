import std/strutils
import nimcrypto

proc sha256Hex*(data: string): string =
  ## Lowercase hex SHA-256, used for token hashes and contract fingerprints.
  toLowerAscii($nimcrypto.sha256.digest(data))
