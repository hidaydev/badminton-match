// src/types/index.ts
// Domain types — single source of truth untuk semua layer.
// Tidak ada dependencies ke store, queries, atau framework.

export const PLAYERS_PER_GAME = 4

// Branded types for type safety
declare const __brand: unique symbol
type Brand<T, B> = T & { readonly [__brand]: B }

export type PlayerId = Brand<string, 'PlayerId'>
export type TimeString = Brand<string, 'TimeString'>  // "HH:MM" format
export type GameKey = Brand<string, 'GameKey'>  // "slot-court" format

/** Create a PlayerId from a string */
export function toPlayerId(id: string): PlayerId {
  return id as PlayerId
}

/** Create a TimeString from a string (no validation — use for known-good values) */
export function toTimeString(s: string): TimeString {
  return s as TimeString
}

/** Create a GameKey from slot and court indices */
export function toGameKey(slot: number, court: number): GameKey {
  return `${slot}-${court}` as GameKey
}

export type Gender = 'M' | 'F'
export type Tier = 1 | 2 | 3 | 4

export interface Player {
  id: PlayerId
  name: string
  gender: Gender
  tier: Tier
}

export type MatchConstraint = MatchConstraintFlexible | MatchConstraintPinned

export interface MatchConstraintFlexible {
  id: string
  slots: [PlayerId, PlayerId, PlayerId, PlayerId] // empty string = any
  mode: 'flexible'
}

export interface MatchConstraintPinned {
  id: string
  slots: [PlayerId, PlayerId, PlayerId, PlayerId] // empty string = any
  mode: 'pinned'
  pinnedTime: TimeString
  pinnedCourt: number   // court index (0-based)
}

/** @deprecated Use MatchConstraint instead */
export type FixMatch = MatchConstraint
/** @deprecated Use MatchConstraintFlexible instead */
export type FixMatchFlexible = MatchConstraintFlexible
/** @deprecated Use MatchConstraintPinned instead */
export type FixMatchPinned = MatchConstraintPinned

export interface ScheduleSlot {
  slot: number   // absolute time slot index
  court: number
  teamA: [PlayerId, PlayerId]
  teamB: [PlayerId, PlayerId]
}

export interface GameScore {
  a: number  // Team A score
  b: number  // Team B score
}

export interface CourtTime {
  start: TimeString
  end: TimeString
}

/** Create a CourtTime, throwing if start >= end. */
export function createCourtTime(start: string, end: string): CourtTime {
  if (start >= end) throw new Error(`Invalid CourtTime: start (${start}) must be before end (${end})`)
  return { start: start as TimeString, end: end as TimeString }
}

export interface SessionConfig {
  title: string
  date: string
  courts: number
  sessionStart: TimeString    // "09:00"
  slotMinutes: number         // minutes per game slot
  courtTimes: CourtTime[]
  playerCount: number
  courtNames: string[]
  locked: boolean
}

export interface CloudSnapshot {
  version?: number
  session: SessionConfig
  players: Player[]
  fixMatches: MatchConstraint[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  absentPlayers?: string[]
}

export interface PlayerSummary {
  name: string
  gender: 'M' | 'F'
  tier: 1 | 2 | 3 | 4
}
