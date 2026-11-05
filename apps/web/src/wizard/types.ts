// Session wizard domain types. The wizard runs entirely in the browser until
// its schedule is published: the server owns sessions, players and games, but
// constraints and the draft roster are local inputs to the generator.

export const PLAYERS_PER_GAME = 4

export type Gender = 'M' | 'F'

/** 1=D, 2=D+, 3=C, 4=C+, 5=B, 6=B+, 7=A, 8=A+ */
export type Tier = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8

export type PlayerId = string

export interface Player {
  id: PlayerId
  name: string
  gender: Gender
  tier: Tier
}

interface MatchConstraintBase {
  id: string
  /** Empty string means "anyone" in that slot. */
  slots: [PlayerId, PlayerId, PlayerId, PlayerId]
}

export interface MatchConstraintFlexible extends MatchConstraintBase {
  mode: 'flexible'
}

export interface MatchConstraintPinned extends MatchConstraintBase {
  mode: 'pinned'
  pinnedTime: string
  /** Court index, 0-based. */
  pinnedCourt: number
}

export type MatchConstraint = MatchConstraintFlexible | MatchConstraintPinned

/** A new constraint before the store assigns its id. */
export type NewMatchConstraint = Omit<MatchConstraintFlexible, 'id'> | Omit<MatchConstraintPinned, 'id'>

/** Fields a constraint editor may change; the mode decides which apply. */
export type FixMatchPatch = {
  slots?: MatchConstraint['slots']
  mode?: 'flexible' | 'pinned'
  pinnedTime?: string
  pinnedCourt?: number
}

export interface ScheduleSlot {
  /** Absolute time slot index, shared across courts. */
  slot: number
  court: number
  teamA: [PlayerId, PlayerId]
  teamB: [PlayerId, PlayerId]
}

export interface GameScore {
  a: number
  b: number
}

export interface CourtTime {
  start: string
  end: string
}

export interface SessionConfig {
  title: string
  date: string
  courts: number
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  playerCount: number
  courtNames: string[]
  locked: boolean
}
