import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'host' }

const config = {
  effective: {
    'export.post_width': { value: 1080, source: 'platform' },
    'export.post_height': { value: 1350, source: 'platform' },
    'export.story_width': { value: 1080, source: 'platform' },
    'export.story_height': { value: 1920, source: 'platform' },
  },
}

const tournament = {
  format: 'classic',
  name: 'Classic Cup',
  date: '2026-11-04',
  pairs: [{ id: 'p1', name: 'Ani & Budi' }],
  groups: { A: ['p1'], B: [], C: [], D: [] },
  matches: [
    {
      id: 'group-A-0',
      phase: 'group',
      groupId: 'A',
      pairAId: 'p1',
      pairBId: null,
      scoreA: null,
      scoreB: null,
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('ExportPage', () => {
  it('lists tournaments and offers the compositions its format supports', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [acme] } }),
      'GET /api/c/acme/config': () => ({ body: config }),
      'GET /api/c/acme/tournaments': () => ({
        body: {
          items: [
            {
              id: 't1',
              name: 'Classic Cup',
              date: '2026-11-04',
              format: 'classic',
              status: 'draft',
              version: 1,
            },
          ],
        },
      }),
      'GET /api/c/acme/tournaments/t1': () => ({ body: tournament }),
    })

    renderAt('/c/acme/export')

    expect(await screen.findByRole('heading', { name: t('export.title') })).toBeInTheDocument()
    const select = await screen.findByLabelText(t('export.tournament'))
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /Classic Cup/ })).toBeInTheDocument(),
    )

    fireEvent.change(select, { target: { value: 't1' } })

    const image = await screen.findByLabelText(t('export.image'))
    await waitFor(() =>
      expect(screen.getByRole('option', { name: t('export.group', { group: 'D' }) })).toBeInTheDocument(),
    )
    expect(screen.getByRole('option', { name: t('export.bracket.final') })).toBeInTheDocument()
    expect(image).toHaveValue('group:A')
  })

  it('treats missing export settings as an error instead of guessing a size', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [acme] } }),
      'GET /api/c/acme/config': () => ({ body: { effective: {} } }),
      'GET /api/c/acme/tournaments': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/export')

    expect(await screen.findByText(t('export.error.config'))).toBeInTheDocument()
  })
})
