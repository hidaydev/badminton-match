import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { GeneratorResult } from '../../generator'
import { useStore } from '../../store'
import { toPlayerId, toTimeString, type Player } from '../../types'
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

describe('GeneratePage replace player', () => {
  beforeEach(() => {
    window.localStorage.clear()
    useStore.setState({
      session: {
        ...useStore.getState().session,
        locked: false,
        playerCount: players.length,
        courts: 1,
        sessionStart: toTimeString('18:00'),
        slotMinutes: 20,
        courtTimes: [{ start: toTimeString('18:00'), end: toTimeString('18:20') }],
        courtNames: [],
      },
      players,
      fixMatches: [],
      schedule: result.schedule,
      lastResult: result,
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
      cloudSessionId: null,
    })
  })

  it('renames the roster entry so publish can resolve the typed player', () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <GeneratePage />
      </QueryClientProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Summary' }))
    fireEvent.click(screen.getByRole('button', { name: 'Actions menu' }))
    fireEvent.click(screen.getByRole('menuitem', { name: /Replace player/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Ani' }))
    fireEvent.change(screen.getByPlaceholderText('New name…'), { target: { value: 'Eka' } })
    fireEvent.click(screen.getByRole('button', { name: '✓ Save' }))

    const state = useStore.getState()
    expect(state.players.map((player) => player.name)).toEqual(['Eka', 'Budi', 'Candra', 'Dewi'])
    // The slot keeps its local id, which the roster entry now maps to "Eka".
    expect(state.players[0].id).toBe(players[0].id)
    expect(state.lastResult?.schedule[0].teamA[0]).toBe(players[0].id)
  })
})