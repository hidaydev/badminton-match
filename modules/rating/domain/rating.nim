import std/[math, options, strutils]

type
  TierBand* = object
    tier*: string
    floor*: float

  RatingParams* = object
    ## Business numbers arrive from the config registry; nothing here defaults.
    sessionBase*: float
    scoreTarget*: int
    opponentClampLow*: float
    opponentClampHigh*: float
    windowWeeks*: int
    bestN*: int
    thinEvidenceN*: int
    bands*: seq[TierBand]

proc clamp*(value, low, high: float): float =
  if value < low: low
  elif value > high: high
  else: value

proc gameValue*(base, margin, target: float): float =
  ## Points for one session game. A drawn-ish game still earns half the base:
  ## there are no appearance points, only a signed margin scaled to the target.
  if target <= 0:
    return 0
  base * (0.5 + 0.5 * clamp(margin / target, -1.0, 1.0))

proc opponentMultiplier*(params: RatingParams, opponentAverage,
                         populationAverage: float): float =
  ## Stronger opposition is worth more, but only inside the configured clamp so
  ## the board never becomes a list of the busiest players.
  if opponentAverage <= 0 or populationAverage <= 0:
    return 1.0
  clamp(opponentAverage / populationAverage, params.opponentClampLow,
    params.opponentClampHigh)

proc roundPoints*(value: float): int =
  ## Rating deltas are integers; rounding happens once, at the edge.
  int(floor(value + 0.5))

proc tierStrength*(params: RatingParams, tier: string): Option[float] =
  ## Midpoint of the tier's band, derived from the ascending floors. The highest
  ## band is open ended, so it stretches 100 points above its floor.
  if tier.len == 0 or params.bands.len == 0:
    return none(float)
  for index, band in params.bands:
    if cmpIgnoreCase(band.tier, tier) != 0:
      continue
    if index + 1 < params.bands.len:
      return some((band.floor + params.bands[index + 1].floor) / 2)
    return some(band.floor + 100)
  none(float)

proc averageTierStrength*(params: RatingParams, tiers: seq[string]): float =
  ## Average of the known tiers; empty or unknown tiers are skipped, so an
  ## unrated pair contributes nothing instead of pulling the average to zero.
  var total = 0.0
  var seen = 0
  for tier in tiers:
    let strength = tierStrength(params, tier)
    if strength.isSome:
      total += strength.get
      inc seen
  if seen == 0: 0.0 else: total / seen.float

proc entryPoints*(params: RatingParams, gamePoints: seq[float],
                  opponentAverage, populationAverage: float): int =
  ## Sums the window's best entries and applies the opponent multiplier. The
  ## caller decides which games make the cut; this only does the arithmetic.
  var total = 0.0
  for points in gamePoints:
    total += points
  total *= opponentMultiplier(params, opponentAverage, populationAverage)
  roundPoints(total)
