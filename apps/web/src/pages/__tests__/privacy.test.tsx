import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../auth/redirect', () => ({ redirectTo: vi.fn() }))
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { mockFetch } from '../../test/fetchMock'

describe('privacy page', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.history.replaceState({}, '', '/privacy')
  })

  it('is readable without a session', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: { code: 'UNAUTHENTICATED' } }),
    })

    render(<App />)

    expect(
      await screen.findByRole('heading', { level: 1, name: 'Privacy Policy' }),
    ).toBeInTheDocument()
    expect(screen.getByText('Last updated: 7 November 2026')).toBeInTheDocument()
    expect(screen.getByText('hello@qouver.com')).toBeInTheDocument()
  })
})