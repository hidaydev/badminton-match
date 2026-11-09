import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { GeneratorResult } from '../../generator'
import { useStore } from '../../store'
import { ApiError, getSession, publishSession, setCommunitySlug } from '../../queries/endpoints'
import { toPlayerId, toTimeString, type Player } from '../../types'
import { t } from '@/i18n'
import { reloadPage } from '../../utils/reload'
import GeneratePage from '../GeneratePage'

vi.mock('../../queries/endpoints', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../queries/endpoints')>()
  return { ...actual, publishSession: vi.fn(), getSession: vi.fn() }
})

vi.mock('../../utils/reload', () => ({ reloadPage: vi.fn() }))

const publishMock = vi.mocked(publishSession)
const getSessionMock = vi.mocked(getSession)
const reloadMock = vi.mocked(reloadPage)

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

describe('GeneratePage stale publish', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme/session/generate')
    setCommunitySlug('acme')
    publishMock.mockReset()
    getSessionMock.mockReset()
    reloadMock.mockReset()
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
      cloudSessionId: 's1',
      cloudVersion: 9,
      pendingPublish: null,
    })
  })

  it('offers a reload, not a retry, when the publish is stale', async () => {
    publishMock.mockRejectedValueOnce(
      new ApiError('session changed since If-Match', 'STALE_VERSION', 412),
    )
    getSessionMock.mockResolvedValue(null)

    render(
      <QueryClientProvider client={new QueryClient()}>
        <GeneratePage />
      </QueryClientProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Summary' }))
    fireEvent.click(screen.getByRole('button', { name: /Played:/ }))

    expect(await screen.findByText(t('session.stale'))).toBeInTheDocument()

    // Resending the same conditional request can only 412 again.
    expect(screen.queryByRole('button', { name: t('session.action.retry') })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: t('session.action.reload') }))

    expect(reloadMock).toHaveBeenCalledTimes(1)
    expect(publishMock).toHaveBeenCalledTimes(1)
  })
})
