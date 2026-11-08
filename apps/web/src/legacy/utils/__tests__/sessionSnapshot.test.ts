import { describe, expect, it } from 'vitest'
import {
  buildPublishableSessionSnapshot,
  replacePlayerNameInSnapshot,
  setPlayedInSnapshot,
  setScoreSetsInSnapshot,
  setSkippedInSnapshot,
  swapSlotsInSnapshot,
} from '../sessionSnapshot'
import { toGameKey, toPlayerId, toTimeString } from '../../types'
import type {
  CloudSnapshot,
  Player,
  ScheduleSlot,
  SessionConfig,
  SessionScoring,
  SetScore,
} from '../../types'

const player = (id: string, name: string): Player => ({
  id: toPlayerId(id),
  name,
  gender: 'M',
  tier: 4,
})

const scoring = (gamesToWin: number): SessionScoring => ({
  preset: 'custom',
  label: 'Custom',
  gamesToWin,
  pointsToWin: 21,
  winBy: 2,
  maxPoints: 30,
  deuceAt: 20,
  changeEndsAt: null,
})

const session = (rules: SessionScoring = scoring(1)): SessionConfig => ({
  title: 'Sunday',
  date: '2026-11-08',
  courts: 2,
  sessionStart: toTimeString('09:00'),
  slotMinutes: 30,
  courtTimes: [],
  playerCount: 8,
  courtNames: [],
  locked: false,
  scoring: rules,
})

const players = [
  player('p1', 'Arya'),
  player('p2', 'Bowo'),
  player('p3', 'Candra'),
  player('p4', 'Dika'),
  player('p5', 'Eka'),
  player('p6', 'Fajar'),
  player('p7', 'Gita'),
  player('p8', 'Hana'),
]

/** Two courts in slot 0 and one court in slot 1: keys "0-0", "0-1", "1-0". */
const schedule: ScheduleSlot[] = [
  { slot: 0, court: 0, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('p4')] },
  { slot: 0, court: 1, teamA: [toPlayerId('p5'), toPlayerId('p6')], teamB: [toPlayerId('p7'), toPlayerId('p8')] },
  { slot: 1, court: 0, teamA: [toPlayerId('p5'), toPlayerId('p2')], teamB: [toPlayerId('p7'), toPlayerId('p4')] },
]

const snapshot = (overrides: Partial<CloudSnapshot> = {}): CloudSnapshot => ({
  version: 3,
  session: session(),
  players,
  fixMatches: [],
  schedule,
  playedGames: [],
  gameScores: {},
  ...overrides,
})

const firstGame = toGameKey(0, 0)
const secondGame = toGameKey(1, 0)
const oneSet: SetScore[] = [{ a: 21, b: 19 }]

describe('setPlayedInSnapshot', () => {
  it('is idempotent: a repeated true keeps the same object', () => {
    const once = setPlayedInSnapshot(snapshot(), firstGame, true)
    const twice = setPlayedInSnapshot(once, firstGame, true)

    expect(twice).toBe(once)
    expect(twice.playedGames).toEqual([firstGame])
  })

  it('drops the recorded score when the game is unmarked', () => {
    const played = snapshot({
      playedGames: [firstGame],
      gameScores: { [firstGame]: { a: 21, b: 19 } },
    })

    const cleared = setPlayedInSnapshot(played, firstGame, false)

    expect(cleared.playedGames).toEqual([])
    expect(cleared.gameScores).toEqual({})
    expect(played.playedGames).toEqual([firstGame])
  })
})

describe('setScoreSetsInSnapshot', () => {
  it('clears both the score and the played entry when the set list is empty', () => {
    const scored = snapshot({
      playedGames: [firstGame],
      gameScores: { [firstGame]: { a: 21, b: 19 } },
    })

    const cleared = setScoreSetsInSnapshot(scored, firstGame, [])

    expect(cleared.gameScores).toEqual({})
    expect(cleared.playedGames).toEqual([])
  })

  it('rejects a key that is not on the schedule', () => {
    expect(() => setScoreSetsInSnapshot(snapshot(), '9-9', oneSet)).toThrow('Invalid game key: 9-9')
  })

  it('marks the game played once the match is complete and leaves it unplayed while undecided', () => {
    const complete = setScoreSetsInSnapshot(snapshot({ session: session(scoring(1)) }), firstGame, oneSet)
    expect(complete.playedGames).toEqual([firstGame])
    expect(complete.gameScores[firstGame]).toEqual({ a: 21, b: 19, sets: [{ a: 21, b: 19 }] })

    // Best of three, one set each: nothing has been won yet.
    const split = setScoreSetsInSnapshot(
      snapshot({ session: session(scoring(2)) }),
      firstGame,
      [{ a: 21, b: 19 }, { a: 19, b: 21 }],
    )
    expect(split.playedGames).toEqual([])
    expect(split.gameScores[firstGame]).toEqual({
      a: 40,
      b: 40,
      sets: [{ a: 21, b: 19 }, { a: 19, b: 21 }],
    })
  })

  it('withdraws the played mark when an earlier complete score becomes a partial one', () => {
    const played = snapshot({ session: session(scoring(2)), playedGames: [firstGame] })

    const partial = setScoreSetsInSnapshot(played, firstGame, oneSet)

    expect(partial.playedGames).toEqual([])
    expect(partial.gameScores[firstGame]).toEqual({ a: 21, b: 19, sets: oneSet })
  })
})

describe('setSkippedInSnapshot', () => {
  it('removes the key when the skip list becomes empty', () => {
    const skipped = setSkippedInSnapshot(snapshot(), firstGame, ['p3'])
    expect(skipped.skippedPlayers).toEqual({ [firstGame]: ['p3'] })

    const cleared = setSkippedInSnapshot(skipped, firstGame, [])
    expect(cleared.skippedPlayers).toEqual({})
    expect(cleared.skippedPlayers).not.toHaveProperty(firstGame)
    expect(skipped.skippedPlayers).toHaveProperty(firstGame)
  })

  it('stores a copy so the caller cannot mutate the snapshot through its array', () => {
    const requested = ['p3']
    const stored = setSkippedInSnapshot(snapshot(), firstGame, requested)

    requested.push('p4')

    expect(stored.skippedPlayers?.[firstGame]).toEqual(['p3'])
    expect(stored.skippedPlayers?.[firstGame]).not.toBe(requested)
  })
})

describe('swapSlotsInSnapshot', () => {
  it('moves playedGames, gameScores and skippedPlayers together with the schedule', () => {
    const before = snapshot({
      playedGames: [firstGame, secondGame],
      gameScores: { [firstGame]: { a: 21, b: 19 } },
      skippedPlayers: { [firstGame]: ['p3'] },
    })

    const swapped = swapSlotsInSnapshot(before, { slot: 0, court: 0 }, { slot: 1, court: 0 })

    expect(swapped.playedGames).toEqual([secondGame, firstGame])
    expect(swapped.gameScores).toEqual({ [secondGame]: { a: 21, b: 19 } })
    expect(swapped.skippedPlayers).toEqual({ [secondGame]: ['p3'] })
    // The game that was on 0-0 now sits on 1-0, and its players moved with it.
    expect(swapped.schedule.find((s) => s.slot === 1 && s.court === 0)?.teamA).toEqual(
      schedule[0].teamA,
    )
    expect(swapped.schedule.find((s) => s.slot === 0 && s.court === 0)?.teamA).toEqual(
      schedule[2].teamA,
    )
    // The source snapshot is untouched.
    expect(before.playedGames).toEqual([firstGame, secondGame])
    expect(before.gameScores).toEqual({ [firstGame]: { a: 21, b: 19 } })
  })

  it('leaves skippedPlayers absent when the snapshot carries none', () => {
    const swapped = swapSlotsInSnapshot(snapshot(), { slot: 0, court: 0 }, { slot: 1, court: 0 })

    expect(swapped.skippedPlayers).toBeUndefined()
  })
})

describe('buildPublishableSessionSnapshot', () => {
  it('always produces absentPlayers, defaulting to an empty list', () => {
    const built = buildPublishableSessionSnapshot({
      version: 7,
      session: session(),
      players,
      fixMatches: [],
      schedule,
      playedGames: [firstGame],
      gameScores: {},
    })

    expect(built.absentPlayers).toEqual([])
    expect(built.version).toBe(7)
    expect(built.playedGames).toEqual([firstGame])
  })

  it('keeps the absent players the server already reported', () => {
    const built = buildPublishableSessionSnapshot({
      version: 7,
      existingAbsentPlayers: ['p9'],
      session: session(),
      players,
      fixMatches: [],
      schedule,
      playedGames: [],
      gameScores: {},
    })

    expect(built.absentPlayers).toEqual(['p9'])
  })
})

describe('replacePlayerNameInSnapshot', () => {
  it('renames only the matching player and keeps the others by reference', () => {
    const before = snapshot()

    const renamed = replacePlayerNameInSnapshot(before, 'p2', 'Bowo Putra')

    expect(renamed.players.find((p) => p.id === 'p2')?.name).toBe('Bowo Putra')
    expect(renamed.players.find((p) => p.id === 'p1')).toBe(before.players[0])
    expect(before.players.find((p) => p.id === 'p2')?.name).toBe('Bowo')
  })
})