// Regression: store slice reset behavior. Bug yang dijaga:
//  - updatePlayer tidak boleh wipe schedule/skor (rename di tengah sesi live).
//  - setter config idempoten (nilai sama) tidak boleh reset schedule/skor.
import test from 'node:test'
import assert from 'node:assert/strict'
import { createPlayersSlice } from '../../src/store/playersSlice.ts'
import { createSessionSlice } from '../../src/store/sessionSlice.ts'
import type { SetState } from '../../src/store/index.ts'
import { toPlayerId, toGameKey } from '../../src/types/index.ts'
import type { Player, ScheduleSlot, GameScore, GameKey } from '../../src/types/index.ts'

type AppState = Parameters<SetState>[0] extends (s: infer S) => unknown ? S : never

function harness(seed: Partial<AppState>) {
  let state = seed as AppState
  const set: SetState = (fn) => {
    state = { ...state, ...fn(state) }
  }
  return { set, get: () => state }
}

const p = (id: string): Player => ({ id: toPlayerId(id), name: id.toUpperCase(), gender: 'M', tier: 3 })

const schedule: ScheduleSlot[] = [
  { slot: 1, court: 0, teamA: [toPlayerId('a'), toPlayerId('b')], teamB: [toPlayerId('c'), toPlayerId('d')] },
]
const key = toGameKey(1, 0)
const scores: Partial<Record<GameKey, GameScore>> = { [key]: { a: 21, b: 10 } }

test('updatePlayer: hanya ubah record pemain, schedule & skor tetap utuh', () => {
  const h = harness({
    players: [p('a'), p('b'), p('c'), p('d')],
    schedule,
    playedGames: [key],
    gameScores: scores as Record<GameKey, GameScore>,
  })
  const slice = createPlayersSlice(h.set)

  slice.updatePlayer(toPlayerId('a'), { name: 'Renamed' })

  const s = h.get()
  assert.equal(s.players[0].name, 'Renamed')
  assert.deepEqual(s.schedule, schedule)
  assert.deepEqual(s.playedGames, [key])
  assert.deepEqual(s.gameScores, scores)
})

test('setCourtTime: nilai sama → tidak reset; nilai beda → reset (perilaku lama)', () => {
  const h = harness({})
  const slice = createSessionSlice(h.set)
  h.set(() => ({ ...slice, schedule, playedGames: [key], gameScores: scores as Record<GameKey, GameScore> }))

  const ct = h.get().session.courtTimes[0]
  slice.setCourtTime(0, ct.start, ct.end)
  assert.deepEqual(h.get().schedule, schedule, 'nilai sama tidak boleh reset schedule')

  slice.setCourtTime(0, '10:00', '12:00')
  assert.deepEqual(h.get().schedule, [], 'nilai beda tetap reset schedule')
})

test('setSlotMinutes: nilai sama tidak reset, nilai beda reset', () => {
  const h = harness({})
  const slice = createSessionSlice(h.set)
  h.set(() => ({ ...slice, schedule, playedGames: [key], gameScores: scores as Record<GameKey, GameScore> }))

  const min = h.get().session.slotMinutes
  slice.setSlotMinutes(min)
  assert.deepEqual(h.get().schedule, schedule)

  slice.setSlotMinutes(min + 5)
  assert.deepEqual(h.get().schedule, [])
})
