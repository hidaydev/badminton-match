import { describe, expect, it } from 'vitest'
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
})
