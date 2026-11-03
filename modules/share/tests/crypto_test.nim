import std/unittest
import ../crypto

suite "share crypto":
  let keys = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

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
    check newShareCode().len == 32
