import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { DeletePanel } from '../PlayerDetailPage'
import { t } from '../../i18n'

/** A fetch that never settles until the test releases it. */
function deferredFetch() {
  let release: (() => void) | null = null
  const calls: string[] = []
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push(`${init?.method ?? 'GET'} ${String(input)}`)
    await new Promise<void>((resolve) => {
      release = resolve
    })
    return {
      ok: true,
      status: 204,
      headers: new Headers(),
      json: async () => ({}),
    } as Response
  })
  vi.stubGlobal('fetch', fetchMock)
  return { calls, release: () => release?.() }
}

describe('player delete', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('sends one request for a double tap and disables both buttons while it runs', async () => {
    const { calls, release } = deferredFetch()
    render(
      <MemoryRouter>
        <DeletePanel slug="acme" playerId="p1" busy={false} />
      </MemoryRouter>,
    )

    fireEvent.click(screen.getByRole('button', { name: t('playerAdmin.delete') }))
    const confirm = screen.getByRole('button', { name: t('playerAdmin.delete.confirmAction') })
    fireEvent.click(confirm)
    fireEvent.click(confirm)

    const pending = await screen.findByRole('button', { name: t('playerAdmin.delete.pending') })
    expect(pending).toBeDisabled()
    expect(screen.getByRole('button', { name: t('playerAdmin.delete.cancel') })).toBeDisabled()
    await waitFor(() => expect(calls).toEqual(['DELETE /api/c/acme/players/p1']))

    release()
  })

  it('re-enables the panel when the request fails', async () => {
    const fetchMock = vi.fn(async () => ({
      ok: false,
      status: 500,
      statusText: 'Server Error',
      headers: new Headers(),
      json: async () => ({ detail: 'boom' }),
    }) as Response)
    vi.stubGlobal('fetch', fetchMock)

    render(
      <MemoryRouter>
        <DeletePanel slug="acme" playerId="p1" busy={false} />
      </MemoryRouter>,
    )

    fireEvent.click(screen.getByRole('button', { name: t('playerAdmin.delete') }))
    fireEvent.click(screen.getByRole('button', { name: t('playerAdmin.delete.confirmAction') }))

    expect(
      await screen.findByRole('button', { name: t('playerAdmin.delete.confirmAction') }),
    ).toBeEnabled()
    expect(screen.getByRole('button', { name: t('playerAdmin.delete.cancel') })).toBeEnabled()
  })
})
