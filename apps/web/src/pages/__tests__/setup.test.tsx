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

  it('names the one-community rule instead of blaming the slug', async () => {
    // ADR-018: a production database answers 409 COMMUNITY_LIMIT for the same
    // status a taken slug uses, so the screen has to read the code.
    mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
      'POST /api/communities': () => ({
        status: 409,
        body: {
          code: 'COMMUNITY_LIMIT',
          detail: 'ADR-018 allows one community per production database',
        },
      }),
    })

    renderAt('/owner/communities')
    fireEvent.change(await screen.findByLabelText(t('setup.slug')), {
      target: { value: 'second-club' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.name')), {
      target: { value: 'Second Club' },
    })
    fireEvent.change(screen.getByLabelText(t('setup.adminEmail')), {
      target: { value: 'admin@example.com' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('setup.submit') }))

    expect(await screen.findByText(t('setup.error.communityLimit'))).toBeInTheDocument()
    expect(screen.queryByText(t('setup.error.slugTaken'))).not.toBeInTheDocument()
  })

  it('keeps the create form closed until its summary is used', async () => {    mockFetch({
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

  it('refuses on a single-community deployment without calling the API', async () => {
    // ADR-018: the boot refuses a production database that holds two
    // communities, so the form must not write the row that would be refused.
    vi.stubEnv('VITE_SINGLE_COMMUNITY', '1')
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
    })

    renderAt('/owner/communities')

    expect(await screen.findByText(t('setup.single.body'))).toBeInTheDocument()
    expect(screen.queryByLabelText(t('setup.slug'))).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: t('setup.submit') })).not.toBeInTheDocument()
    const posted = fetchMock.mock.calls.some(
      ([url, init]) =>
        String(url) === '/api/communities' &&
        (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(posted).toBe(false)
  })

  it('shows the form when the deployment flag is absent', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: owner }),
      'GET /api/communities': () => ({ body: { items: [admin] } }),
    })

    renderAt('/owner/communities')

    expect(await screen.findByLabelText(t('setup.slug'))).toBeInTheDocument()
    expect(screen.queryByText(t('setup.single.body'))).not.toBeInTheDocument()
  })
})
