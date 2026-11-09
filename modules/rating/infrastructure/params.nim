import std/[json, options]
import platform/config/store
import ../domain/rating

proc loadRatingParams*(snapshot: Snapshot, settings: JsonNode): RatingParams =
  ## Reads every number the point formula needs. A malformed clamp or band list
  ## is a configuration error, not something to paper over with a default.
  result.sessionBase = decimalValue(snapshot, settings, keyRatingSessionBase)
  result.scoreTarget = intValue(snapshot, settings, keyRatingScoreTarget)
  result.windowWeeks = intValue(snapshot, settings, keyRatingWindowWeeks)
  result.bestN = intValue(snapshot, settings, keyRatingBestN)
  result.thinEvidenceN = intValue(snapshot, settings, keyRatingThinEvidenceN)
  result.topBandWidth = intValue(snapshot, settings, keyRatingTopBandWidth)

  let clamp = jsonValue(snapshot, settings, keyRatingOpponentClamp)
  if clamp.kind != JArray or clamp.len != 2:
    raise newException(ConfigError, "rating.opponent_clamp must be a two-element array")
  result.opponentClampLow = clamp[0].getFloat()
  result.opponentClampHigh = clamp[1].getFloat()
  if result.opponentClampLow <= 0 or
     result.opponentClampHigh < result.opponentClampLow:
    raise newException(ConfigError, "rating.opponent_clamp must be positive and ordered")

  for band in jsonValue(snapshot, settings, keyRatingTierBands):
    if band.kind != JObject or not band.hasKey("tier") or not band.hasKey("min"):
      raise newException(ConfigError, "rating.tier_bands entries need tier and min")
    var ceiling = none(float)
    if band.hasKey("max") and band["max"].kind != JNull:
      ceiling = some(band["max"].getFloat())
      if ceiling.get <= band["min"].getFloat():
        raise newException(ConfigError,
          "rating.tier_bands max must be above min")
    result.bands.add(TierBand(tier: band["tier"].getStr(),
      floor: band["min"].getFloat(), ceiling: ceiling))
