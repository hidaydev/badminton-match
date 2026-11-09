import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen } from '@testing-library/react'
import { t } from '@/i18n'
import { mockFetch } from '@/test/fetchMock'
import ShareLinkPanel from './ShareLinkPanel'

const SESSION = 's1'
const SHARE_PATH = `/api/c/plan/sessions/${SESSION}/share`

let writeText: ReturnType<typeof vi.fn>

function installClipboard() {
  writeText = vi.fn()
  writeText.mockResolvedValue(undefined)
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText },
  })
}

function renderPanel() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <ShareLinkPanel sessionId={SESSION} />
    </QueryClientProvider>,
  )
}

function openPanel() {
  fireEvent.click(screen.getByRole('button', { name: t('session.share') }))
}

const urlFor = (code: string) => `${window.location.origin}/s/${code}`

beforeEach(() => {
  window.history.replaceState({}, '', '/c/plan')
  installClipboard()
})

afterEach(() => {
  Reflect.deleteProperty(navigator, 'clipboard')
})

describe('ShareLinkPanel', () => {
  it('offers to create a link when there is none, then shows the full share URL', async () => {
    const fetchMock = mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({
        status: 404,
        body: { status: 404, code: 'NOT_FOUND', detail: 'no share link' },
      }),
      [`POST ${SHARE_PATH}`]: () => ({ body: { code: 'K7x9' } }),
    })

    renderPanel()
    openPanel()

    expect(await screen.findByText(t('session.share.none'))).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: t('session.share.create') }))

    expect(await screen.findByText(urlFor('K7x9'))).toBeInTheDocument()
    expect(screen.getByRole('link', { name: t('session.share.open') })).toHaveAttribute(
      'href',
      urlFor('K7x9'),
    )
    const posts = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url) === SHARE_PATH && (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(posts).toHaveLength(1)
  })

  it('copies the URL while creating and switches the button to the copied label', async () => {
    mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({
        status: 404,
        body: { status: 404, code: 'NOT_FOUND' },
      }),
      [`POST ${SHARE_PATH}`]: () => ({ body: { code: 'K7x9' } }),
    })

    renderPanel()
    openPanel()
    fireEvent.click(await screen.findByRole('button', { name: t('session.share.create') }))

    expect(
      await screen.findByRole('button', { name: t('session.share.copied') }),
    ).toBeInTheDocument()
    expect(writeText).toHaveBeenCalledTimes(1)
    expect(writeText).toHaveBeenCalledWith(urlFor('K7x9'))
  })

  it('keeps a working Copy button after the automatic clipboard write is rejected', async () => {
    // The first (automatic) write is refused, the manual click succeeds.
    writeText.mockRejectedValueOnce(new Error('clipboard blocked'))
    mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({
        status: 404,
        body: { status: 404, code: 'NOT_FOUND' },
      }),
      [`POST ${SHARE_PATH}`]: () => ({ body: { code: 'K7x9' } }),
    })

    renderPanel()
    openPanel()
    fireEvent.click(await screen.findByRole('button', { name: t('session.share.create') }))

    const copy = await screen.findByRole('button', { name: t('session.share.copy') })
    expect(writeText).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('alert')).toBeNull()

    fireEvent.click(copy)

    expect(
      await screen.findByRole('button', { name: t('session.share.copied') }),
    ).toBeInTheDocument()
    expect(writeText).toHaveBeenCalledTimes(2)
    expect(writeText).toHaveBeenLastCalledWith(urlFor('K7x9'))
  })

  it('rotates the code in place without closing the sheet', async () => {
    const fetchMock = mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({ body: { code: 'old-code' } }),
      [`POST ${SHARE_PATH}`]: () => ({ body: { code: 'new-code' } }),
    })

    renderPanel()
    openPanel()
    expect(await screen.findByText(urlFor('old-code'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('session.share.rotate') }))

    expect(await screen.findByText(urlFor('new-code'))).toBeInTheDocument()
    expect(screen.queryByText(urlFor('old-code'))).toBeNull()
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(
      fetchMock.mock.calls.some(
        ([url, init]) =>
          String(url) === SHARE_PATH && (init as RequestInit | undefined)?.method === 'POST',
      ),
    ).toBe(true)
  })

  it('asks for confirmation and only then sends the DELETE', async () => {
    let revoked = false
    const fetchMock = mockFetch({
      [`GET ${SHARE_PATH}`]: () =>
        revoked
          ? { status: 404, body: { status: 404, code: 'NOT_FOUND' } }
          : { body: { code: 'abc' } },
      [`DELETE ${SHARE_PATH}`]: () => {
        revoked = true
        return { status: 204 }
      },
    })

    renderPanel()
    openPanel()
    expect(await screen.findByText(urlFor('abc'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('session.share.revoke') }))

    expect(screen.getByText(t('session.share.revokeConfirm'))).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: t('session.share.revoke') })).toBeNull()
    expect(
      fetchMock.mock.calls.some(
        ([url, init]) =>
          String(url) === SHARE_PATH && (init as RequestInit | undefined)?.method === 'DELETE',
      ),
    ).toBe(false)

    fireEvent.click(screen.getByRole('button', { name: t('session.share.revokeYes') }))

    await screen.findByText(t('session.share.none'))
    const deletes = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url) === SHARE_PATH && (init as RequestInit | undefined)?.method === 'DELETE',
    )
    expect(deletes).toHaveLength(1)
  })

  it('clears the panel when the revoke is confirmed, even if the follow-up read is refused', async () => {
    // The read after the DELETE is refused (400 is not retried), so only the
    // panel's own cache clear can empty the sheet.
    let revoked = false
    mockFetch({
      [`GET ${SHARE_PATH}`]: () =>
        revoked
          ? { status: 400, body: { status: 400, code: 'INVALID_BODY', detail: 'nope' } }
          : { body: { code: 'abc' } },
      [`DELETE ${SHARE_PATH}`]: () => {
        revoked = true
        return { status: 204 }
      },
    })

    renderPanel()
    openPanel()
    expect(await screen.findByText(urlFor('abc'))).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('session.share.revoke') }))
    fireEvent.click(screen.getByRole('button', { name: t('session.share.revokeYes') }))

    expect(await screen.findByText(t('session.share.none'))).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: t('session.share.create') }),
    ).toBeInTheDocument()
    expect(screen.queryByText(urlFor('abc'))).toBeNull()
  })

  it('returns focus to the Revoke button when the confirmation is cancelled', async () => {
    mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({ body: { code: 'abc' } }),
    })

    renderPanel()
    openPanel()
    await screen.findByText(urlFor('abc'))

    fireEvent.click(screen.getByRole('button', { name: t('session.share.revoke') }))
    const confirm = screen.getByRole('button', { name: t('session.share.revokeYes') })
    expect(document.activeElement).toBe(confirm)

    fireEvent.click(screen.getByRole('button', { name: t('session.share.cancel') }))

    expect(document.activeElement).toBe(
      screen.getByRole('button', { name: t('session.share.revoke') }),
    )
  })

  it('shows the share error text when a mutation is rejected', async () => {
    mockFetch({
      [`GET ${SHARE_PATH}`]: () => ({ body: { code: 'abc' } }),
      [`POST ${SHARE_PATH}`]: () => ({
        status: 500,
        body: { status: 500, code: 'INTERNAL', detail: 'boom' },
      }),
    })

    renderPanel()
    openPanel()
    await screen.findByText(urlFor('abc'))

    fireEvent.click(screen.getByRole('button', { name: t('session.share.rotate') }))

    expect(await screen.findByRole('alert')).toHaveTextContent(t('session.share.error'))
    expect(screen.getByText(urlFor('abc'))).toBeInTheDocument()
  })
})