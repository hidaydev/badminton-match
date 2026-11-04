import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const shared = {
  session: {
    id: 's1',
    title: 'Tuesday Night',
    date: '2026-11-03',
    status: 'locked',
  },
  community: { slug: 'acme', name: 'Acme' },
  games: [
    {
      id: 'g1',
      round: 0,
      court: 0,
      sideA: ['Ani', 'Budi'],
      sideB: ['Candra', 'Dewi'],
      scoreA: 30,
      scoreB: 24,
      status: 'played',
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('shared session', () => {
  it('renders the games a stranger came to see, without any control', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/abc123': () => ({ body: shared }),
    })

    renderAt('/s/abc123')

    expect(await screen.findByRole('heading', { name: 'Tuesday Night' })).toBeInTheDocument()
    expect(screen.getByText('Ani & Budi')).toBeInTheDocument()
    expect(screen.getByText('30–24')).toBeInTheDocument()
    expect(screen.getByText('Acme')).toBeInTheDocument()
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('says the link is gone instead of showing an empty session', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/rotated': () => ({ status: 404, body: { code: 'NOT_FOUND' } }),
    })

    renderAt('/s/rotated')

    expect(await screen.findByText(t('shared.error.missing'))).toBeInTheDocument()
  })
})
