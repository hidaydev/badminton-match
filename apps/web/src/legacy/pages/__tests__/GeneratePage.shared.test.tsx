import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { GeneratorResult } from '../../generator'
import { SharedViewContext } from '../../sharedView'
import { useStore } from '../../store'
import { toPlayerId, toTimeString, type Player } from '../../types'
import type { SharedSnapshot } from '../../utils/shareUrl'
import GeneratePage from '../GeneratePage'

const players: Player[] = [
  { id: toPlayerId('p1'), name: 'Ani', gender: 'F', tier: 3 },
  { id: toPlayerId('p2'), name: 'Budi', gender: 'M', tier: 3 },
  { id: toPlayerId('p3'), name: 'Candra', gender: 'M', tier: 3 },
  { id: toPlayerId('p4'), name: 'Dewi', gender: 'F', tier: 3 },
]

const result: GeneratorResult = {
  schedule: [
    {
      slot: 0,
      court: 0,
      teamA: [players[0].id, players[1].id],
      teamB: [players[2].id, players[3].id],
    },
  ],
  playCount: {},
  sitCount: {},
  partnerWith: {},
  facedBy: {},
  unplacedFixMatches: [],
}

const snapshot: SharedSnapshot = {
  sessionId: 'shared-session',
  session: {
    title: 'Sunday Social',
    date: '2026-11-01',
    courts: 1,
    sessionStart: toTimeString('09:00'),
    slotMinutes: 20,
    courtTimes: [{ start: toTimeString('09:00'), end: toTimeString('11:00') }],
    playerCount: players.length,
    courtNames: [],
    locked: true,
  },
  players,
  schedule: result.schedule,
  lastResult: result,
}

function renderShared() {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <SharedViewContext.Provider
        value={{ snapshot, isSharedView: true, exitSharedView: () => {} }}
      >
        <GeneratePage />
      </SharedViewContext.Provider>
    </QueryClientProvider>,
  )
}

function openSummary() {
  fireEvent.click(screen.getByRole('button', { name: 'Summary' }))
}

describe('GeneratePage shared view', () => {
  beforeEach(() => {
    window.localStorage.clear()
    // A draft for some unrelated session sits in the store; the shared link
    // must read its own snapshot and leave this draft untouched.
    useStore.setState({
      session: {
        ...useStore.getState().session,
        locked: false,
        playerCount: players.length,
        courts: 1,
        sessionStart: toTimeString('09:00'),
        slotMinutes: 20,
        courtTimes: [{ start: toTimeString('09:00'), end: toTimeString('11:00') }],
      },
      players,
      lastResult: result,
      schedule: result.schedule,
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
      cloudSessionId: null,
    })
  })

  it('offers no editing controls to a spectator', () => {
    renderShared()
    openSummary()

    expect(
      screen.queryByRole('button', { name: 'Actions menu' }),
    ).not.toBeInTheDocument()
  })

  it('never writes a spectator edit into the draft store', () => {
    renderShared()
    openSummary()

    fireEvent.click(
      screen.getByRole('button', { name: /Played: Ani & Budi vs Candra & Dewi/ }),
    )

    const state = useStore.getState()
    expect(state.playedGames).toEqual([])
    expect(state.gameScores).toEqual({})
    expect(state.lastResult?.schedule[0]).toEqual(result.schedule[0])
  })
})