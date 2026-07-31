import test from 'node:test'
import assert from 'node:assert/strict'
import {
  buildPublishableSessionSnapshot,
  setScoreInSnapshot,
  swapSlotsInSnapshot,
  togglePlayedInSnapshot,
} from '../../src/utils/sessionSnapshot.ts'
import type { CloudSnapshot } from '../../src/queries/types.ts'
import { toTimeString, toPlayerId, toGameKey } from '../../src/types/index.ts'

function makeSnapshot(): CloudSnapshot {
  return {
    version: 3,
    session: {
      title: 'Test Session',
      date: '2026-06-18',
      courts: 2,
      sessionStart: toTimeString('09:00'),
      slotMinutes: 20,
      courtTimes: [
        { start: toTimeString('09:00'), end: toTimeString('10:00') },
        { start: toTimeString('09:00'), end: toTimeString('10:00') },
      ],
      playerCount: 8,
      courtNames: [],
      locked: true,
    },
    players: [
      { id: toPlayerId('p1'), name: 'A', gender: 'M', tier: 1 },
      { id: toPlayerId('p2'), name: 'B', gender: 'M', tier: 2 },
      { id: toPlayerId('p3'), name: 'C', gender: 'F', tier: 3 },
      { id: toPlayerId('p4'), name: 'D', gender: 'F', tier: 4 },
    ],
    fixMatches: [],
    schedule: [
      { slot: 0, court: 0, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('p4')] },
      { slot: 1, court: 1, teamA: [toPlayerId('p1'), toPlayerId('p3')], teamB: [toPlayerId('p2'), toPlayerId('p4')] },
    ],
    playedGames: ['0-0'],
    gameScores: {
      [toGameKey(0, 0)]: { a: 30, b: 27 },
    },
    absentPlayers: [toPlayerId('p4')],
  }
}

test('togglePlayedInSnapshot removes orphan score when unplaying a game', () => {
  const snapshot = makeSnapshot()
  const next = togglePlayedInSnapshot(snapshot, '0-0')

  assert.deepEqual(next.playedGames, [])
  assert.equal(next.gameScores[toGameKey(0, 0)], undefined)
  assert.deepEqual(next.absentPlayers, ['p4'])
})

test('setScoreInSnapshot auto-adds played game when scoring an unplayed slot', () => {
  const snapshot = makeSnapshot()
  const next = setScoreInSnapshot(snapshot, '1-1', 21, 18)

  assert.deepEqual(next.playedGames, ['0-0', '1-1'])
  assert.deepEqual(next.gameScores[toGameKey(1, 1)], { a: 21, b: 18 })
})

test('swapSlotsInSnapshot migrates schedule, played keys, and scores together', () => {
  const snapshot = makeSnapshot()
  const next = swapSlotsInSnapshot(
    snapshot,
    { slot: 0, court: 0 },
    { slot: 1, court: 1 },
  )

  assert.deepEqual(next.schedule[0], { slot: 1, court: 1, teamA: ['p1', 'p2'], teamB: ['p3', 'p4'] })
  assert.deepEqual(next.schedule[1], { slot: 0, court: 0, teamA: ['p1', 'p3'], teamB: ['p2', 'p4'] })
  assert.deepEqual(next.playedGames, ['1-1'])
  assert.deepEqual(next.gameScores[toGameKey(1, 1)], { a: 30, b: 27 })
  assert.equal(next.gameScores[toGameKey(0, 0)], undefined)
})

test('buildPublishableSessionSnapshot preserves existing absent players', () => {
  const snapshot = makeSnapshot()
  const published = buildPublishableSessionSnapshot({
    version: snapshot.version,
    existingAbsentPlayers: snapshot.absentPlayers,
    session: snapshot.session,
    players: snapshot.players,
    fixMatches: snapshot.fixMatches,
    schedule: snapshot.schedule,
    playedGames: snapshot.playedGames,
    gameScores: snapshot.gameScores,
  })

  assert.deepEqual(published.absentPlayers, ['p4'])
})
