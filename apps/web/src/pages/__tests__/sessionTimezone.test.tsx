import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { setActiveTimeZone } from '../../utils/day'
import { useStore } from '../../legacy/store'
import { mockFetch } from '../../test/fetchMock'

const admin = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

function handlers(timeZone: string) {
  return mockFetch({
    'GET /api/auth/me': () => ({
      body: { id: 'u1', displayName: 'Ada', platformOwner: false },
    }),
    'GET /api/communities': () => ({ body: { items: [admin] } }),
    'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
    'GET /api/c/acme/config': () => ({
      body: {
        effective: { 'community.default_timezone': { value: timeZone, source: 'community' } },
        scoringPresets: [],
      },
    }),
  })
}

async function defaultDate(): Promise<string> {
  const input = (await screen.findByLabelText('Date')) as HTMLInputElement
  return input.value
}

describe('community timezone', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.history.replaceState({}, '', '/c/acme/session/new')
    // 16:30 UTC is 23:30 WIB on the 3rd and 00:30 WITA on the 4th.
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-03T16:30:00Z'))
    useStore.getState().resetSession()
  })

  afterEach(() => {
    useStore.getState().resetSession()
    setActiveTimeZone(null)
    vi.useRealTimers()
  })

  it('opens the session draft on the default zone day', async () => {
    handlers('Asia/Jakarta')

    render(<App />)

    expect(await defaultDate()).toBe('2026-11-03')
  })

  it('follows a community that set another zone', async () => {
    handlers('Asia/Makassar')

    render(<App />)

    expect(await defaultDate()).toBe('2026-11-04')
  })
})
