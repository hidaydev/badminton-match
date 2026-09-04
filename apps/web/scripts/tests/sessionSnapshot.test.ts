import test from 'node:test'
import assert from 'node:assert/strict'
import {
  buildPublishableSessionSnapshot,
  setScoreInSnapshot,
  swapSlotsInSnapshot,
  togglePlayedInSnapshot,
  setAbsentPlayersInSnapshot,
  replacePlayerNameInSnapshot,
} from '../../src/utils/sessionSnapshot.ts'
import type { CloudSnapshot, Player, ScheduleSlot, SessionConfig } from '../../src/types/index.ts'
import { toGameKey, toPlayerId, toTimeString } from '../../src/types/index.ts'

function makeSnapshot(): CloudSnapshot {
  const players: Player[] = [
    { id: toPlayerId('p1'), name: 'One', gender: 'M', tier: 1 },
    { id: toPlayerId('p2'), name: 'Two', gender: 'F', tier: 2 },
    { id: toPlayerId('p3'), name: 'Three', gender: 'M', tier: 3 },
    { id: toPlayerId('p4'), name: 'Four', gender: 'M', tier: 4 },
  ]
  const schedule: ScheduleSlot[] = [
    { slot: 0, court: 0, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('p4')] },
    { slot: 1, court: 0, teamA: [toPlayerId('p1'), toPlayerId('p3')], teamB: [toPlayerId('p2'), toPlayerId('p4')] },
  ]
  const session: SessionConfig = {
    title: 'Test', date: '2026-08-12', courts: 1, sessionStart: toTimeString('09:00'),
    slotMinutes: 20, courtTimes: [{ start: toTimeString('09:00'), end: toTimeString('10:00') }],
    playerCount: 4, courtNames: ['C1'], locked: false,
  }
  return {
    session, players, fixMatches: [], schedule,
    playedGames: [], gameScores: {}, absentPlayers: [],
  }
}

test('buildPublishableSessionSnapshot: mempertahankan absent player existing', () => {
  const snap = buildPublishableSessionSnapshot({
    session: makeSnapshot().session,
    players: makeSnapshot().players,
    fixMatches: [],
    schedule: makeSnapshot().schedule,
    playedGames: ['0-0'],
    gameScores: { [toGameKey(0, 0)]: { a: 21, b: 18 } },
    existingAbsentPlayers: ['p4'],
    version: 7,
  })
  assert.equal(snap.version, 7)
  assert.deepEqual(snap.absentPlayers, ['p4'])
  assert.deepEqual(snap.playedGames, ['0-0'])
})

test('togglePlayedInSnapshot: menandai played', () => {
  const out = togglePlayedInSnapshot(makeSnapshot(), '0-0')
  assert.ok(out.playedGames.includes('0-0'))
})

test('togglePlayedInSnapshot: unplay menghapus skor orphan', () => {
  const snap = makeSnapshot()
  snap.playedGames = ['0-0']
  snap.gameScores = { [toGameKey(0, 0)]: { a: 21, b: 18 } }
  const out = togglePlayedInSnapshot(snap, '0-0')
  assert.ok(!out.playedGames.includes('0-0'))
  assert.ok(!(toGameKey(0, 0) in out.gameScores))
})

test('setScoreInSnapshot: auto-tambah ke playedGames saat game belum played', () => {
  const out = setScoreInSnapshot(makeSnapshot(), '0-0', 21, 18)
  assert.ok(out.playedGames.includes('0-0'))
  assert.deepEqual(out.gameScores[toGameKey(0, 0)], { a: 21, b: 18 })
})

test('setScoreInSnapshot: menolak skor tidak valid (sama/negatif)', () => {
  const snap = makeSnapshot()
  assert.throws(() => setScoreInSnapshot(snap, '0-0', 21, 21), /Scores cannot be equal/)
  assert.throws(() => setScoreInSnapshot(snap, '0-0', -1, 5), /Scores cannot be negative/)
  assert.throws(() => setScoreInSnapshot(snap, '9-9', 21, 18), /Invalid game key/)
})

test('swapSlotsInSnapshot: memigrasikan schedule, played keys, dan scores bersama', () => {
  const snap = makeSnapshot()
  snap.playedGames = ['0-0']
  snap.gameScores = { [toGameKey(0, 0)]: { a: 21, b: 18 } }
  const out = swapSlotsInSnapshot(snap, { slot: 0, court: 0 }, { slot: 1, court: 0 })

  // game 0-0 sekarang di slot 1
  assert.ok(out.playedGames.includes('1-0'))
  assert.ok(!out.playedGames.includes('0-0'))
  assert.deepEqual(out.gameScores[toGameKey(1, 0)], { a: 21, b: 18 })
  assert.ok(!(toGameKey(0, 0) in out.gameScores))

  // schedule ikut pindah
  const moved = out.schedule.find((g) => g.slot === 1 && g.court === 0)!
  assert.deepEqual(moved.teamA, ['p1', 'p2'])
})

test('setAbsentPlayersInSnapshot: mengganti daftar absent', () => {
  const out = setAbsentPlayersInSnapshot(makeSnapshot(), ['p4', 'p3'])
  assert.deepEqual(out.absentPlayers, ['p4', 'p3'])
})

test('replacePlayerNameInSnapshot: rename hanya pemain yang dituju', () => {
  const out = replacePlayerNameInSnapshot(makeSnapshot(), 'p2', 'Dua Baru')
  assert.equal(out.players.find((p) => p.id === 'p2')?.name, 'Dua Baru')
  assert.equal(out.players.find((p) => p.id === 'p1')?.name, 'One')
})

test('semua helper snapshot bersifat immutable', () => {
  const snap = makeSnapshot()
  const before = JSON.stringify(snap)
  setScoreInSnapshot(snap, '0-0', 21, 18)
  togglePlayedInSnapshot(snap, '0-0')
  setAbsentPlayersInSnapshot(snap, ['p4'])
  replacePlayerNameInSnapshot(snap, 'p1', 'X')
  assert.equal(JSON.stringify(snap), before)
})
