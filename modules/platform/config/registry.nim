type
  ConfigType* = enum
    ctInt = "int"
    ctDecimal = "decimal"
    ctBool = "bool"
    ctString = "string"
    ctJson = "json"

  ConfigScope* = enum
    csPlatform = "platform"
    csCommunity = "community"

  ConfigKey* = enum
    ## Registry keys frozen in TECH-SPEC §4A. The enum value is the database key.
    keyCommunityDefaultTimezone = "community.default_timezone"
    keyCommunityDirectoryEnabled = "community.directory_enabled"
    keyCommunityInviteTtlDays = "community.invite_ttl_days"
    keyCommunityJoinRequestsEnabled = "community.join_requests_enabled"
    keyIngestTickerMinutes = "ingest.ticker_minutes"
    keyApiPageSizeDefault = "api.page_size_default"
    keyRankBoardLimit = "rank.board_limit"
    keyRankMinSessions = "rank.min_sessions"
    keyRatingSessionBase = "rating.session_base"
    keyRatingScoreTarget = "rating.score_target"
    keyRatingOpponentClamp = "rating.opponent_clamp"
    keyRatingWindowWeeks = "rating.window_weeks"
    keyRatingBestN = "rating.best_n"
    keyRatingThinEvidenceN = "rating.thin_evidence_n"
    keyRatingTierBands = "rating.tier_bands"
    keyExportPostWidth = "export.post_width"
    keyExportPostHeight = "export.post_height"
    keyExportStoryWidth = "export.story_width"
    keyExportStoryHeight = "export.story_height"
    keySecurityAllowedOrigins = "security.allowed_origins"
    keySecurityRateLimitPerMinute = "security.rate_limit_per_minute"
    keySecurityMaxBodyBytes = "security.max_body_bytes"
    keySecurityMaxJsonDepth = "security.max_json_depth"
    keySecurityReadTimeoutMs = "security.read_timeout_ms"
    keySecurityJoinRequestRate = "security.join_request_rate"
    keySecurityShareScrapeLimit = "security.share_scrape_limit"
    keyWsMaxWatchersPerSession = "ws.max_watchers_per_session"
    keyWsMaxWatchersPerIp = "ws.max_watchers_per_ip"
    keyWsMaxWatchersProcess = "ws.max_watchers_process"
    keyWsTicketTtlSeconds = "ws.ticket_ttl_seconds"
    keySessionAbsoluteDays = "session.absolute_days"
    keySessionIdleDays = "session.idle_days"
    keyAuthFlowTtlMinutes = "auth.flow_ttl_minutes"
    keyJanitorRetentionDays = "janitor.retention_days"
    keyAuditRetentionDays = "audit.retention_days"

  KeySpec* = object
    key*: ConfigKey
    kind*: ConfigType
    scope*: ConfigScope
    minValue*: float
    maxValue*: float
    hasBounds*: bool

proc spec(key: ConfigKey, kind: ConfigType, minValue = 0.0,
          maxValue = 0.0, hasBounds = false,
          scope = csPlatform): KeySpec =
  KeySpec(key: key, kind: kind, scope: scope, minValue: minValue,
    maxValue: maxValue, hasBounds: hasBounds)

const allKeys* = [
  spec(keyCommunityDefaultTimezone, ctString, scope = csCommunity),
  spec(keyCommunityDirectoryEnabled, ctBool, scope = csCommunity),
  spec(keyCommunityInviteTtlDays, ctInt, 1, 365, true,
    scope = csCommunity),
  spec(keyCommunityJoinRequestsEnabled, ctBool, scope = csCommunity),
  spec(keyIngestTickerMinutes, ctInt, 1, 1440, true),
  spec(keyApiPageSizeDefault, ctInt, 1, 1000, true),
  spec(keyRankBoardLimit, ctInt, 1, 10_000, true),
  spec(keyRankMinSessions, ctInt, 0, 100, true),
  spec(keyRatingSessionBase, ctDecimal, 0, 100_000, true),
  spec(keyRatingScoreTarget, ctInt, 1, 99, true, scope = csCommunity),
  spec(keyRatingOpponentClamp, ctJson),
  spec(keyRatingWindowWeeks, ctInt, 1, 520, true),
  spec(keyRatingBestN, ctInt, 1, 100, true),
  spec(keyRatingThinEvidenceN, ctInt, 0, 100, true),
  spec(keyRatingTierBands, ctJson),
  spec(keyExportPostWidth, ctInt, 320, 4096, true),
  spec(keyExportPostHeight, ctInt, 320, 4096, true),
  spec(keyExportStoryWidth, ctInt, 320, 4096, true),
  spec(keyExportStoryHeight, ctInt, 320, 4096, true),
  spec(keySecurityAllowedOrigins, ctJson),
  spec(keySecurityRateLimitPerMinute, ctInt, 1, 100_000, true),
  spec(keySecurityMaxBodyBytes, ctInt, 1024, 16_777_216, true),
  spec(keySecurityMaxJsonDepth, ctInt, 1, 64, true),
  spec(keySecurityReadTimeoutMs, ctInt, 100, 300_000, true),
  spec(keySecurityJoinRequestRate, ctInt, 1, 1000, true),
  spec(keySecurityShareScrapeLimit, ctInt, 1, 10_000, true),
  spec(keyWsMaxWatchersPerSession, ctInt, 1, 100_000, true),
  spec(keyWsMaxWatchersPerIp, ctInt, 1, 100_000, true),
  spec(keyWsMaxWatchersProcess, ctInt, 1, 1_000_000, true),
  spec(keyWsTicketTtlSeconds, ctInt, 5, 3600, true),
  spec(keySessionAbsoluteDays, ctInt, 1, 365, true),
  spec(keySessionIdleDays, ctInt, 1, 90, true),
  spec(keyAuthFlowTtlMinutes, ctInt, 1, 60, true),
  spec(keyJanitorRetentionDays, ctInt, 1, 3650, true),
  spec(keyAuditRetentionDays, ctInt, 1, 3650, true),
]

proc specFor*(key: ConfigKey): KeySpec =
  for candidate in allKeys:
    if candidate.key == key:
      return candidate
  raise newException(ValueError, "key is not in the registry: " & $key)

proc isRequired*(): bool =
  ## Every registry key is required in L1. A missing key stops the process.
  true
