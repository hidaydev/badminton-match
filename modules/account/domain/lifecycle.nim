import sha256

type
  AnonymizedIdentity* = object
    ## The three columns that survive anonymisation. Nothing else about the
    ## person is kept; `email_hash` becomes a derived marker so a second run can
    ## recognise an account that is already gone.
    sub*: string
    emailHash*: string
    displayName*: string

proc marker*(userId: string): string =
  sha256Hex("anonymized:" & userId)

proc anonymizedIdentity*(sub, userId: string): AnonymizedIdentity =
  ## `google_sub` becomes sha256(sub). The login callback looks for that derived
  ## value before creating an account, so a later login for the same subject is
  ## refused instead of quietly opening a second, empty account.
  AnonymizedIdentity(sub: sha256Hex(sub), emailHash: marker(userId),
    displayName: "")

proc isAnonymized*(emailHash, userId: string): bool =
  emailHash == marker(userId)
