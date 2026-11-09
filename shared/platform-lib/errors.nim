import std/json
import logger

type
  Problem* = object
    status*: int
    code*: string
    i18nKey*: string
    detail*: string

proc newProblem*(status: int, code, i18nKey: string, detail = ""): Problem =
  Problem(status: status, code: code, i18nKey: i18nKey, detail: detail)

proc toJson*(problem: Problem): string =
  ## RFC 9457-shaped body. Detail is redacted like any other log-bound value.
  let node = %*{
    "type": "about:blank",
    "title": problem.code,
    "status": problem.status,
    "code": problem.code,
    "i18nKey": problem.i18nKey,
    "detail": redact(problem.detail),
  }
  $node

const
  unknownI18nKey* = "error.unknown"
  # One table owns the code -> translation key mapping. Adding a business code
  # without an entry here is caught by apps/api/tests/problem_envelope_test.nim.
  i18nKeys* = [
    ("ACCOUNT_ANONYMIZED", "error.accountAnonymized"),
    ("ALIAS_TAKEN", "error.aliasTaken"),
    ("BODY_TOO_LARGE", "error.bodyTooLarge"),
    ("CLAIMANT_OWNS_PLAYER", "error.claimantOwnsPlayer"),
    ("CLAIMED", "error.claimed"),
    ("CLAIM_CONFLICT", "error.claimConflict"),
    ("CLAIM_PENDING", "error.claimPending"),
    ("CLIENT_OUTDATED", "error.clientOutdated"),
    ("CONFLICT", "error.conflict"),
    ("CSRF_REJECTED", "error.csrfRejected"),
    ("FORBIDDEN", "error.forbidden"),
    ("IDEMPOTENCY_CONFLICT", "error.idempotencyConflict"),
    ("IDEMPOTENCY_IN_PROGRESS", "error.idempotencyInProgress"),
    ("INTERNAL", "error.internal"),
    ("INVALID_ALIAS", "error.invalidAlias"),
    ("INVALID_BODY", "error.invalidBody"),
    ("INVALID_CALLBACK", "error.invalidCallback"),
    ("INVALID_COMMUNITY", "error.invalidCommunity"),
    ("INVALID_CONFIG_VALUE", "error.invalidConfigValue"),
    ("INVALID_DECISION", "error.invalidDecision"),
    ("INVALID_EMAIL", "error.invalidEmail"),
    ("INVALID_GAME_KEY", "error.invalidGameKey"),
    ("INVALID_ID_TOKEN", "error.invalidIdToken"),
    ("INVALID_INPUT", "error.invalidInput"),
    ("INVALID_PATCH", "error.invalidPatch"),
    ("INVALID_PLAYER", "error.invalidPlayer"),
    ("INVALID_PRECONDITION", "error.invalidPrecondition"),
    ("INVALID_PRESET", "error.invalidPreset"),
    ("INVALID_ROLE", "error.invalidRole"),
    ("INVALID_SCHEDULE", "error.invalidSchedule"),
    ("INVALID_SCORE", "error.invalidScore"),
    ("INVALID_SESSION", "error.invalidSession"),
    ("INVALID_SET_SEQUENCE", "error.invalidSetSequence"),
    ("INVALID_STATE", "error.invalidState"),
    ("INVALID_SWAP", "error.invalidSwap"),
    ("INVALID_TOURNAMENT", "error.invalidTournament"),
    ("INVITE_EMAIL_MISMATCH", "error.inviteEmailMismatch"),
    ("INVITE_EXPIRED", "error.inviteExpired"),
    ("INVITE_NOT_FOUND", "error.inviteNotFound"),
    ("INVITE_USED", "error.inviteUsed"),
    ("KEY_ERROR", "error.keyError"),
    ("LAST_ADMIN", "error.lastAdmin"),
    ("MATCH_HAS_SETS", "error.matchHasSets"),
    ("MERGE_CONFLICT", "error.mergeConflict"),
    ("MERGE_PAIR_CONFLICT", "error.mergePairConflict"),
    ("MERGE_SESSION_CONFLICT", "error.mergeSessionConflict"),
    ("METHOD", "error.method"),
    ("NONCE_MISMATCH", "error.nonceMismatch"),
    ("NOT_FOUND", "error.notFound"),
    ("NOT_PARTICIPANT", "error.notParticipant"),
    ("NOT_READY", "error.notReady"),
    ("NOT_RATED", "error.notRated"),
    ("OVERRIDE_TOO_HIGH", "error.overrideTooHigh"),
    ("PLATFORM_CONFIG_KEY", "error.platformConfigKey"),
    ("PLAYER_EXISTS", "error.playerExists"),
    ("PRECONDITION_REQUIRED", "error.preconditionRequired"),
    ("PRESET_LOCKED", "error.presetLocked"),
    ("RATE_LIMITED", "error.rateLimited"),
    ("REASON_REQUIRED", "error.reasonRequired"),
    ("SAME_PLAYER", "error.samePlayer"),
    ("SELF_DECISION", "error.selfDecision"),
    ("SETS_REQUIRED", "error.setsRequired"),
    ("SLUG_TAKEN", "error.slugTaken"),
    ("STALE_VERSION", "error.staleVersion"),
    ("TOKEN_EXCHANGE_FAILED", "error.tokenExchangeFailed"),
    ("UNAUTHENTICATED", "error.unauthenticated"),
    ("UNAVAILABLE", "error.unavailable"),
    ("UNKNOWN_CONFIG_KEY", "error.unknownConfigKey"),
    ("UNKNOWN_PLAYER", "error.unknownPlayer"),
    ("UPGRADE_REQUIRED", "error.upgradeRequired"),
    ("USER_UPSERT_FAILED", "error.userUpsertFailed"),
  ]

proc i18nKeyFor*(code: string): string =
  ## The client translates this key; an unmapped code still answers a valid
  ## key so the body shape never depends on the table's completeness.
  for (known, key) in i18nKeys:
    if known == code:
      return key
  return unknownI18nKey
