import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'

const owner = { id: 'u1', displayName: 'Ada', platformOwner: true }
const admin = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('community setup', () => {
  it('opens a community and names the first admin', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
      'POST /api/communities': () => ({
        status: 201,
        body: { id: 'c2', slug: 'badminton-jkt', name: 'Badminton JKT', timezone: 'Asia/Jakarta' },
      }),
    })

    renderAt('/owner/communities')

    fireEvent.change(await screen.findByLabelText(t('setup.slug')), {
      target: { value: 'badminton-jkt' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.name')), {
      target: { value: 'Badminton JKT' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.adminEmail')), {
      target: { value: 'admin@example.com' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('setup.submit') }))

    expect(await screen.findByText(t('setup.created', { name: 'Badminton JKT' }))).toBeInTheDocument()
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/communities' &&
        (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
      slug: 'badminton-jkt',
      name: 'Badminton JKT',
      adminEmail: 'admin@example.com',
    })
  })

  it('says why a taken slug is refused', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
      'POST /api/communities': () => ({
        status: 409,
        body: { code: 'SLUG_TAKEN', detail: 'community slug already exists' },
      }),
    })

    renderAt('/owner/communities')
    fireEvent.change(await screen.findByLabelText(t('setup.slug')), {
      target: { value: 'acme' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.name')), {
      target: { value: 'Acme' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.adminEmail')), {
      target: { value: 'admin@example.com' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('setup.submit') }))

    expect(await screen.findByText(t('setup.error.slugTaken'))).toBeInTheDocument()
  })

  it('keeps the create form closed until its summary is used', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
    })

    renderAt('/owner/communities')

    const slug = await screen.findByLabelText(t('setup.slug'))
    const panel = slug.closest('details')
    if (!(panel instanceof HTMLDetailsElement)) {
      throw new Error('the create form is not a disclosure element')
    }
    expect(panel.open).toBe(false)

    fireEvent.click(screen.getByText(t('setup.create'), { selector: 'summary' }))
    expect(panel.open).toBe(true)
  })

  it('offers the create form to a platform owner on a production build', async () => {
    // Multi-community is live, so nothing about the build may hold the form
    // back: the deployment that ships this bundle is the one that serves
    // several communities. A regression here would hide the product's headline
    // feature in the only build that reaches people.
    vi.stubEnv('PROD', true)

    mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
    })

    renderAt('/owner/communities')

    expect(await screen.findByLabelText(t('setup.slug'))).toBeInTheDocument()
    expect(screen.getByRole('button', { name: t('setup.submit') })).toBeInTheDocument()
  })
})
