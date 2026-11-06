import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../auth/redirect', () => ({ redirectTo: vi.fn() }))
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'
import { redirectTo } from '../../auth/redirect'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('invitation acceptance', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('explains the link and signs in back to the same invitation', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: { code: 'UNAUTHENTICATED' } }),
      'POST /api/auth/start': () => ({
        body: { authorizeUrl: 'https://accounts.example/authorize?state=1', keyId: 'k1' },
      }),
    })

    renderAt('/invites/tok_1')

    expect(
      await screen.findByRole('heading', { name: t('invite.title') }),
    ).toBeInTheDocument()
    expect(screen.getByText(t('invite.signedOutHint'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('invite.signIn') }))

    await waitFor(() => expect(redirectTo).toHaveBeenCalledTimes(1))
    const startCall = fetchMock.mock.calls.find(([url]) => String(url).endsWith('/auth/start'))
    expect(jsonBody((startCall as [string, RequestInit])[1])).toEqual({
      returnTo: '/invites/tok_1',
    })
  })

  it('accepts, then shows the granted role and a link into the community', async () => {
    let membershipReads = 0
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => {
        membershipReads += 1
        return {
          body: {
            items:
              membershipReads === 1
                ? []
                : [{ id: 'c1', slug: 'acme', name: 'Acme', role: 'host' }],
          },
        }
      },
      'POST /api/invites/tok_1/accept': () => ({
        status: 201,
        body: { communityId: 'c1', role: 'host' },
      }),
    })

    renderAt('/invites/tok_1')

    fireEvent.click(await screen.findByRole('button', { name: t('invite.accept') }))

    expect(
      await screen.findByText(t('invite.accepted', { role: t('role.host') })),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: t('invite.open') })).toHaveAttribute(
      'href',
      '/c/acme',
    )

    const acceptCall = fetchMock.mock.calls.find(
      ([url]) => String(url) === '/api/invites/tok_1/accept',
    )
    expect((acceptCall as [string, RequestInit])[1].method).toBe('POST')
    // The response only names the community by id, so the list is re-read once.
    expect(membershipReads).toBe(2)
  })

  it.each([
    { status: 410, code: 'INVITE_USED', key: 'invite.error.used' as const },
    { status: 410, code: 'INVITE_EXPIRED', key: 'invite.error.expired' as const },
    { status: 403, code: 'INVITE_EMAIL_MISMATCH', key: 'invite.error.emailMismatch' as const },
    { status: 404, code: 'INVITE_NOT_FOUND', key: 'invite.error.notFound' as const },
  ])('maps $status $code to its own message', async ({ status, code, key }) => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [] } }),
      'POST /api/invites/tok_1/accept': () => ({ status, body: { code } }),
    })

    renderAt('/invites/tok_1')

    fireEvent.click(await screen.findByRole('button', { name: t('invite.accept') }))

    expect(await screen.findByRole('alert')).toHaveTextContent(t(key))
  })
})