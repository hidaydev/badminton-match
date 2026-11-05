import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import { setCommunitySlug } from './endpoints'
import { useGetPlayerStats } from './players'
import { useRatingPlayer } from './ratings'

const PLAYER_ID = '11111111-1111-1111-1111-111111111111'

const stats = {
  playerId: PLAYER_ID,
  name: 'Budi',
  tier: 'B',
  gender: 'M',
  points: 12,
  games: 4,
  wins: 3,
  losses: 1,
  history: [
    {
      date: '2026-01-01',
      title: 'Session',
      gameRef: '1-0',
      outcome: 'W',
      scoreA: 21,
      scoreB: 10,
      teammates: [],
      opponents: [],
    },
  ],
  sessions: [{ id: 's1', date: '2026-01-01', title: 'Session' }],
  topPartners: [],
  topOpponents: [],
}

describe('player stats sharing', () => {
  beforeEach(() => {
    setCommunitySlug('majadu')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('serves the rating card and the career card from one request', async () => {
    const fetchMock = mockFetch({
      [`GET /api/c/majadu/players/${PLAYER_ID}/stats`]: () => ({ body: stats }),
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    const { result } = renderHook(
      () => ({
        rating: useRatingPlayer(PLAYER_ID),
        career: useGetPlayerStats(PLAYER_ID),
      }),
      {
        wrapper: ({ children }) => (
          <QueryClientProvider client={client}>{children}</QueryClientProvider>
        ),
      },
    )

    await waitFor(() => expect(result.current.rating.data).toBeDefined())
    await waitFor(() => expect(result.current.career.data).toBeDefined())

    expect(result.current.rating.data?.name).toBe('Budi')
    expect(result.current.career.data?.gamesPlayed).toBe(4)
    // The same `/stats` payload feeds both cards; a second key would fetch it
    // twice (BEP-06).
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})