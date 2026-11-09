import { beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { mockFetch } from '../../../test/fetchMock'
import { t } from '../../../i18n'
import { LegacySlugProvider } from '../../router'
import { clearStoreDraft, useStore } from '../../store'
import { ApiError, getSession, publishSession, setCommunitySlug } from '../../queries/endpoints'
import type { CloudSnapshot } from '../../types'
import SessionListPage from '../SessionListPage'

vi.mock('../../queries/endpoints', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../queries/endpoints')>()
  return { ...actual, publishSession: vi.fn(), getSession: vi.fn() }
})

const publishMock = vi.mocked(publishSession)
const getSessionMock = vi.mocked(getSession)

type ApiRow = {
  id: string
  title: string
  date: string
  status: string
  playerCount?: number
  totalGames?: number
}

const LIST = '/api/c/acme/sessions?limit=100'

function apiRow(row: Pick<ApiRow, 'id' | 'title' | 'date' | 'status'> & Partial<ApiRow>): ApiRow {
  return { playerCount: 8, totalGames: 6, ...row }
}

function list() {
  return [
    apiRow({
      id: 's1',
      title: 'Tuesday doubles',
      date: '2026-11-03',
      status: 'open',
      playerCount: 8,
      totalGames: 6,
    }),
    apiRow({
      id: 's2',
      title: 'Sunday night',
      date: '2026-11-01',
      status: 'locked',
      playerCount: 12,
      totalGames: 9,
    }),
  ]
}

function LocationProbe() {
  return <span data-testid="pathname">{useLocation().pathname}</span>
}

function renderList() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={['/c/acme/sessions']}>
        <LegacySlugProvider slug="acme">
          <Routes>
            <Route path="/c/acme/sessions" element={<SessionListPage />} />
            <Route path="*" element={<LocationProbe />} />
          </Routes>
        </LegacySlugProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('SessionListPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    // The request path and the query key both read the slug from the URL.
    window.history.replaceState({}, '', '/c/acme')
    // The adapter slug is what the pending-publish guard reads.
    setCommunitySlug('acme')
    useStore.getState().setPendingPublish(null)
    publishMock.mockReset()
    getSessionMock.mockReset()
  })

  it('sends the date filter to the server and counts the filtered page against its total', async () => {
    const fetchMock = mockFetch({
      [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }),
      [`GET ${LIST}&date=2026-11-03`]: () => ({
        body: { items: [list()[0]], total: 1 },
      }),
    })

    renderList()

    expect(await screen.findByText('Tuesday doubles')).toBeInTheDocument()
    // Unfiltered: the header is the server's count alone.
    expect(screen.getByText(`${2} ${t('common.total')}`)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText(t('sessions.filterDate')), {
      target: { value: '2026-11-03' },
    })

    // The filter is debounced by the hook, so wait for the request itself.
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(
          ([url]) => String(url) === `${LIST}&date=2026-11-03`,
        ),
      ).toBe(true),
    )

    // Filtered: the header switches to "loaded / total for this filter".
    expect(await screen.findByText(`1 / 1 ${t('common.total')}`)).toBeInTheDocument()
    expect(screen.queryByText('Sunday night')).not.toBeInTheDocument()
  })

  it('shows the empty state for a filtered result with no rows, and clearing the filter brings them back', async () => {
    mockFetch({
      [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }),
      [`GET ${LIST}&date=2026-10-30`]: () => ({ body: { items: [], total: 0 } }),
    })

    renderList()
    expect(await screen.findByText('Tuesday doubles')).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText(t('sessions.filterDate')), {
      target: { value: '2026-10-30' },
    })

    expect(await screen.findByText(t('sessions.noSessionsFound'))).toBeInTheDocument()
    expect(screen.queryByText('Tuesday doubles')).not.toBeInTheDocument()
    expect(screen.queryByText('Sunday night')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('sessions.clearFilters') }))

    expect(await screen.findByText('Sunday night')).toBeInTheDocument()
    expect(screen.getByText('Tuesday doubles')).toBeInTheDocument()
    expect(screen.queryByText(t('sessions.noSessionsFound'))).not.toBeInTheDocument()
    expect(screen.getByText(`${2} ${t('common.total')}`)).toBeInTheDocument()
  })

  it('labels a locked session as locked and an open one as in progress', async () => {
    mockFetch({ [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }) })

    renderList()

    expect(await screen.findByText('Sunday night')).toBeInTheDocument()

    const lockedRow = screen.getByText('Sunday night').closest('button')!
    expect(within(lockedRow).getByText(t('sessions.locked'))).toBeInTheDocument()
    expect(within(lockedRow).queryByText(t('sessions.active'))).not.toBeInTheDocument()

    const openRow = screen.getByText('Tuesday doubles').closest('button')!
    expect(within(openRow).getByText(t('sessions.active'))).toBeInTheDocument()
    expect(within(openRow).queryByText(t('sessions.locked'))).not.toBeInTheDocument()
  })

  it('asks for the next offset when load more is clicked and appends the second page', async () => {
    const fetchMock = mockFetch({
      [`GET ${LIST}`]: () => ({
        body: { items: list(), total: 3, nextCursor: 2 },
      }),
      [`GET ${LIST}&offset=2`]: () => ({
        body: {
          items: [
            apiRow({ id: 's3', title: 'Monday mixer', date: '2026-10-27', status: 'open' }),
          ],
          total: 3,
        },
      }),
    })

    renderList()

    expect(await screen.findByText('Tuesday doubles')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('sessions.loadMore') }))

    expect(await screen.findByText('Monday mixer')).toBeInTheDocument()
    expect(screen.getByText('Tuesday doubles')).toBeInTheDocument()
    expect(
      fetchMock.mock.calls.some(([url]) => String(url) === `${LIST}&offset=2`),
    ).toBe(true)
    // The second page carries no cursor, so the control goes away.
    expect(
      screen.queryByRole('button', { name: t('sessions.loadMore') }),
    ).not.toBeInTheDocument()
  })

  it('retries with the current version so a stale basis can recover', async () => {
    mockFetch({ [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }) })
    const snapshot: CloudSnapshot = {
      version: 3,
      session: useStore.getState().session,
      players: [],
      fixMatches: [],
      schedule: [],
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
    }
    useStore.getState().setCloudSessionId('s1')
    useStore.getState().setPendingPublish({
      cloudSessionId: 's1',
      snapshot,
      message: t('session.action.failed'),
    })
    // The server has moved on since the snapshot was taken.
    getSessionMock.mockResolvedValueOnce({ ...snapshot, version: 7 })
    publishMock.mockResolvedValueOnce({ ...snapshot, version: 8 })

    renderList()

    expect(await screen.findByText(t('sessions.unsaved.title'))).toBeInTheDocument()
    expect(screen.getByText(t('session.action.failed'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('sessions.unsaved.retry') }))

    await waitFor(() =>
      expect(publishMock).toHaveBeenCalledWith('s1', { ...snapshot, version: 7 }),
    )
    await waitFor(() => expect(screen.queryByText(t('sessions.unsaved.title'))).toBeNull())
    expect(useStore.getState().pendingPublish).toBeNull()
    expect(useStore.getState().cloudVersion).toBe(8)
  })

  it('does not recreate the record when the retry rejects after expiry', async () => {
    mockFetch({ [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }) })
    const snapshot: CloudSnapshot = {
      version: 3,
      session: useStore.getState().session,
      players: [],
      fixMatches: [],
      schedule: [],
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
    }
    useStore.getState().setCloudSessionId('s1')
    useStore.getState().setPendingPublish({
      cloudSessionId: 's1',
      snapshot,
      message: t('session.action.failed'),
    })
    getSessionMock.mockResolvedValueOnce({ ...snapshot, version: 7 })
    let rejectPublish: (error: unknown) => void = () => {}
    publishMock.mockImplementationOnce(
      () => new Promise((_resolve, reject) => { rejectPublish = reject }),
    )

    renderList()
    expect(await screen.findByText(t('sessions.unsaved.title'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('sessions.unsaved.retry') }))
    await waitFor(() => expect(publishMock).toHaveBeenCalledTimes(1))

    // The session ends while the retry is still open.
    act(() => {
      clearStoreDraft()
      setCommunitySlug('')
    })
    rejectPublish(new ApiError('401 UNAUTHENTICATED', 'UNAUTHENTICATED', 401))
    await waitFor(() => expect(useStore.getState().pendingPublish).toBeNull())
    expect(window.localStorage.getItem('badminton-store') ?? '').not.toContain('pendingPublish')
  })

  it('dismisses a failed publish only when the user asks', async () => {
    mockFetch({ [`GET ${LIST}`]: () => ({ body: { items: list(), total: 2 } }) })
    const snapshot: CloudSnapshot = {
      version: 3,
      session: useStore.getState().session,
      players: [],
      fixMatches: [],
      schedule: [],
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
    }
    useStore.getState().setPendingPublish({
      cloudSessionId: 's1',
      snapshot,
      message: t('session.action.failed'),
    })

    renderList()

    expect(await screen.findByText(t('sessions.unsaved.title'))).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: t('sessions.unsaved.dismiss') }))

    expect(screen.queryByText(t('sessions.unsaved.title'))).toBeNull()
  })
})