import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import App from '../../../App'
import GlobalAmbiguousNames from '../GlobalAmbiguousNames'
import { useAmbiguousNames } from '../AmbiguousNamesContext'
import { mockFetch } from '../../../test/fetchMock'
import { t } from '../../../i18n'

const membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

/** Two players who share the bare name, which is what makes it ambiguous. */
const roster = [
  { id: 'p1', name: 'Arya (Dika)', gender: 'M', tier: 'C', userId: null, createdAt: '', updatedAt: '' },
  { id: 'p2', name: 'Arya (Shania)', gender: 'F', tier: 'C', userId: null, createdAt: '', updatedAt: '' },
]

function rosterReads(fetchMock: ReturnType<typeof mockFetch>): string[] {
  return fetchMock.mock.calls
    .map(([url]) => String(url))
    .filter((url) => url.includes('/players?limit=1000'))
}

describe('roster read', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('is issued once for a cold community screen', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({
        body: { id: 'u1', displayName: 'Ada', platformOwner: false },
      }),
      'GET /api/communities': () => ({ body: { items: [membership] } }),
      'GET /api/c/acme/players?limit=1000': () => ({ body: { items: roster } }),
      'GET /api/c/acme/sessions?limit=100&offset=0': () => ({
        body: { items: [], total: 0, nextCursor: '' },
      }),
    })
    window.history.replaceState({}, '', '/c/acme/sessions')

    render(<App />)
    await screen.findByRole('heading', { name: t('sessions.title') })

    await waitFor(() => expect(rosterReads(fetchMock).length).toBeGreaterThan(0))
    expect(rosterReads(fetchMock)).toHaveLength(1)
  })

  it('still feeds the ambiguity badge when two players share a base name', async () => {
    mockFetch({
      'GET /api/c/acme/players?limit=1000': () => ({ body: { items: roster } }),
    })

    function Probe() {
      const names = useAmbiguousNames()
      return <p>{[...names].sort().join(',')}</p>
    }

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: 0 } } })}>
        <MemoryRouter>
          <GlobalAmbiguousNames>
            <Probe />
          </GlobalAmbiguousNames>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    expect(await screen.findByText('arya')).toBeInTheDocument()
  })
})
