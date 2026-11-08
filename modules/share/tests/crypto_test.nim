import std/[base64, sets, strutils, unittest]
import ../crypto
import token

const keys = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

proc ascending(first: int): ByteSource =
  ## A deterministic source so the exact code can be asserted.
  result = proc(count: int): seq[byte] =
    for index in 0 ..< count:
      result.add(byte(first + index))

proc twoKeyRing(): string =
  ## The same all-zero key first, then an all-`0x01` key as the active one, so
  ## a blob really was written under the retired id.
  "{\"1\":\"" & encode(newString(32)) & "\",\"2\":\"" &
    encode(repeat('\x01', 32)) & "\"}"

proc keyOf(bytes: int): string =
  ## A base64 key of exactly `bytes` bytes, so the length check is the thing
  ## that fails rather than the JSON.
  encode(repeat('\x02', bytes))

suite "share crypto":
  test "round-trips with AAD":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    check keyId == "1"
    check decryptWith(keyring, keyId, blob, "community|link") == "abc123"

  test "rejects a different AAD":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, blob, "other|link")

  test "code has 128 bits":
    let code = newShareCode()
    check code.len == 32
    check code == code.toLowerAscii()
    check code.allCharsInSet({'0'..'9', 'a'..'f'})

  test "codes do not repeat":
    var seen = initHashSet[string]()
    for _ in 0 ..< 10_000:
      seen.incl(newShareCode())
    check seen.len == 10_000

  test "newShareCode renders the injected bytes exactly":
    check newShareCode(ascending(0)) == "000102030405060708090a0b0c0d0e0f"

  test "two injected sources produce different share codes":
    check newShareCode(ascending(0)) != newShareCode(ascending(64))

suite "keyring validation":
  test "an empty document or an empty active id is refused":
    expect ShareKeyError:
      discard loadKeyring("", "1")
    expect ShareKeyError:
      discard loadKeyring(keys, "")

  test "a key that is not 32 bytes is refused":
    for length in [31, 33]:
      expect ShareKeyError:
        discard loadKeyring("{\"1\":\"" & keyOf(length) & "\"}", "1")

  test "an active id outside the document is refused":
    expect ShareKeyError:
      discard loadKeyring(keys, "2")

suite "envelope validation":
  test "an empty blob, a wrong version byte and a short blob are refused":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, @[], "community|link")
    var wrongVersion = blob
    wrongVersion[0] = 2
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, wrongVersion, "community|link")
    # 29 bytes is the last length that cannot hold a nonce, a tag and a body.
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, blob[0 ..< 28], "community|link")
    check decryptWith(keyring, keyId, blob, "community|link") == "abc123"

  test "one flipped ciphertext byte fails authentication":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    var tampered = blob
    tampered[1 + 12] = byte(tampered[1 + 12] xor 0x01)
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, tampered, "community|link")

  test "one flipped tag byte fails authentication":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    var tampered = blob
    tampered[^1] = byte(tampered[^1] xor 0x01)
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, tampered, "community|link")

  test "a flipped nonce byte fails authentication":
    let keyring = loadKeyring(keys, "1")
    let (keyId, blob) = encryptWith(keyring, "abc123", "community|link")
    var tampered = blob
    tampered[1] = byte(tampered[1] xor 0x01)
    expect ShareKeyError:
      discard decryptWith(keyring, keyId, tampered, "community|link")

suite "key rotation":
  test "a blob written under the retired key still decrypts":
    let retiredRing = loadKeyring(twoKeyRing(), "1")
    let (retiredId, blob) = encryptWith(retiredRing, "abc123", "community|link")
    check retiredId == "1"
    let current = loadKeyring(twoKeyRing(), "2")
    check current.active == "2"
    check decryptWith(current, retiredId, blob, "community|link") == "abc123"

  test "writing always uses the active id":
    let current = loadKeyring(twoKeyRing(), "2")
    let (keyId, blob) = encryptWith(current, "abc123", "community|link")
    check keyId == "2"
    check decryptWith(current, keyId, blob, "community|link") == "abc123"
    expect ShareKeyError:
      discard decryptWith(current, "3", blob, "community|link")