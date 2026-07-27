// src/config/generator.ts
// Named constants for the schedule generator algorithm.

/** Penalty weight for repeated partner pairings. */
export const PARTNER_PENALTY = 3

/** Penalty weight for repeated opponent pairings. */
export const OPPONENT_PENALTY = 1

/** Penalty weight for tier difference between teams. */
export const TIER_DIFF_WEIGHT = 2

/** Default tier when player tier is unknown. */
export const DEFAULT_TIER = 2

/** Number of random shuffles to try when grouping players into courts. */
export const GROUPING_TRIES = 40

/** Maximum number of candidate players to consider when filling empty slots. */
export const FILL_CANDIDATES = 8

/** Maximum generation attempts in the retry loop. */
export const MAX_GENERATION_ATTEMPTS = 30

/** Scoring weights — injectable via generate() options. */
export interface ScoringWeights {
  partnerPenalty: number
  opponentPenalty: number
  tierDiffWeight: number
}

/** Default scoring weights. */
export const DEFAULT_SCORING: ScoringWeights = {
  partnerPenalty: PARTNER_PENALTY,
  opponentPenalty: OPPONENT_PENALTY,
  tierDiffWeight: TIER_DIFF_WEIGHT,
}
