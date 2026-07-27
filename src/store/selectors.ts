// src/store/selectors.ts
// Computed selectors for derived state — avoids storing computed values.

import type { SessionConfig } from '../types'
import { computeSlotAllocation } from '../utils/time'

/** Compute slotsPerCourt and totalGames from session config. */
export function selectSlotAllocation(session: SessionConfig) {
  return computeSlotAllocation(session.courtTimes, session.slotMinutes)
}

/** Get slotsPerCourt array. */
export function selectSlotsPerCourt(session: SessionConfig): number[] {
  return selectSlotAllocation(session).slotsPerCourt
}

/** Get totalGames count. */
export function selectTotalGames(session: SessionConfig): number {
  return selectSlotAllocation(session).totalGames
}
