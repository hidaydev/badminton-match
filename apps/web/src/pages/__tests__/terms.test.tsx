import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../auth/redirect', () => ({ redirectTo: vi.fn() }))
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { mockFetch } from '../../test/fetchMock'

describe('terms page', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.history.replaceState({}, '', '/terms')
  })

  it('is readable without a session and links security reports to the private advisory', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: { code: 'UNAUTHENTICATED' } }),
    })

    render(<App />)

    expect(
      await screen.findByRole('heading', { level: 1, name: 'Terms of Service' }),
    ).toBeInTheDocument()
    expect(screen.getByText('Last updated: 7 November 2026')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'private security advisory' })).toHaveAttribute(
      'href',
      'https://github.com/hidaydev/badminton-match/security/advisories/new',
    )
  })
})
