import std/[base64, json, strutils, sysrand]
import nimcrypto

type
  ShareKeyError* = object of CatchableError
  Keyring* = object
    active*: string
    keys*: seq[(string, array[32, byte])]

const
  nonceLen = 12
  tagLen = 16
  version = 1'u8

proc decodeKey(value: string): array[32, byte] =
  let raw = decode(value)
  if raw.len != 32:
    raise newException(ShareKeyError, "share key must be 32 bytes")
  for index in 0 ..< 32:
    result[index] = byte(raw[index])

proc loadKeyring*(raw, activeKeyId: string): Keyring =
  ## The caller reads the environment; this module only parses and validates.
  if raw.len == 0:
    raise newException(ShareKeyError, "SHARE_CODE_KEYS is required")
  result.active = activeKeyId
  if result.active.len == 0:
    raise newException(ShareKeyError, "SHARE_CODE_ACTIVE_KEY_ID is required")
  let document = parseJson(raw)
  for keyId, value in document:
    result.keys.add((keyId, decodeKey(value.getStr())))
  var found = false
  for (keyId, _) in result.keys:
    if keyId == result.active:
      found = true
  if not found:
    raise newException(ShareKeyError, "active share key is missing from SHARE_CODE_KEYS")

proc keyFor(keyring: Keyring, keyId: string): array[32, byte] =
  for (candidate, key) in keyring.keys:
    if candidate == keyId:
      return key
  raise newException(ShareKeyError, "unknown share key: " & keyId)

proc randomBytes(count: int): seq[byte] =
  result = newSeq[byte](count)
  if not urandom(result):
    raise newException(ShareKeyError, "cannot read random bytes")

proc aesKeyBytes(key: array[32, byte]): seq[byte] =
  for byteValue in key:
    result.add(byteValue)

proc encrypt*(plaintext, aad: string, key: array[32, byte]): seq[byte] =
  ## version(1) || nonce(12) || ciphertext || tag(16)
  let nonce = randomBytes(nonceLen)
  var ciphertext = newSeq[byte](plaintext.len)
  var tag: array[tagLen, byte]
  var ctx: GCM[aes256]
  ctx.init(aesKeyBytes(key), nonce, aad.toOpenArrayByte(0, aad.len - 1))
  ctx.encrypt(plaintext.toOpenArrayByte(0, plaintext.len - 1), ciphertext, tag)
  result.add(version)
  result.add(nonce)
  result.add(ciphertext)
  for byteValue in tag:
    result.add(byteValue)

proc decrypt*(blob: seq[byte], aad: string, key: array[32, byte]): string =
  if blob.len < 1 + nonceLen + tagLen or blob[0] != version:
    raise newException(ShareKeyError, "invalid ciphertext envelope")
  let nonce = blob[1 ..< 1 + nonceLen]
  let ciphertext = blob[1 + nonceLen ..< blob.len - tagLen]
  let tag = blob[blob.len - tagLen .. ^1]
  var plaintext = newSeq[byte](ciphertext.len)
  var ctx: GCM[aes256]
  ctx.init(aesKeyBytes(key), nonce, aad.toOpenArrayByte(0, aad.len - 1))
  if not ctx.decrypt(ciphertext, plaintext, tag):
    raise newException(ShareKeyError, "ciphertext authentication failed")
  result = newString(plaintext.len)
  for index in 0 ..< plaintext.len:
    result[index] = char(plaintext[index])

proc encryptWith*(keyring: Keyring, plaintext, aad: string): (string, seq[byte]) =
  ## Returns (key id, envelope) for the active key.
  (keyring.active, encrypt(plaintext, aad, keyring.keyFor(keyring.active)))

proc decryptWith*(keyring: Keyring, keyId: string, blob: seq[byte],
                  aad: string): string =
  decrypt(blob, aad, keyring.keyFor(keyId))

proc newShareCode*(): string =
  ## 128-bit code rendered as lowercase hex.
  var bytes = randomBytes(16)
  result = newStringOfCap(32)
  for byteValue in bytes:
    result.add(toHex(byteValue, 2).toLowerAscii)
