import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { t } from '../../i18n'
import { mockFetch } from '../../../test/fetchMock'
import AccountSessions from '../AccountSessions'

const current = {
  id: 's-current',
  createdAt: '2026-11-01 10:00:00+07',
  lastSeenAt: '2026-11-02 09:00:00+07',
  current: true,
}
const other = {
  id: 's-other',
  createdAt: '2026-10-01 08:00:00+07',
  lastSeenAt: '2026-10-20 18:00:00+07',
  current: false,
}

describe('account sessions', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('lists devices and signs out the others', async () => {
    let loads = 0
    const fetchMock = mockFetch({
      'GET /api/auth/sessions': () => {
        loads += 1
        return { body: { items: loads === 1 ? [current, other] : [current] } }
      },
      'DELETE /api/auth/sessions': () => ({ status: 204 }),
    })

    render(<AccountSessions onClose={() => {}} />)

    expect(await screen.findByText(t('sessions.current'))).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: t('sessions.signOutOthers') }))
    fireEvent.click(screen.getByRole('button', { name: t('sessions.confirmAction') }))

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url, init]) =>
            String(url) === '/api/auth/sessions' &&
            (init as RequestInit | undefined)?.method === 'DELETE',
        ),
      ).toBe(true)
    })
    // The list is reloaded, and with only this device left the control is gone.
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: t('sessions.signOutOthers') }),
      ).not.toBeInTheDocument()
    })
    expect(loads).toBe(2)
  })

  it('closes on Escape', async () => {
    mockFetch({
      'GET /api/auth/sessions': () => ({ body: { items: [current] } }),
    })
    const onClose = vi.fn()

    render(<AccountSessions onClose={onClose} />)

    const dialog = await screen.findByRole('dialog')
    fireEvent.keyDown(dialog, { key: 'Escape' })
    expect(onClose).toHaveBeenCalled()
  })
})