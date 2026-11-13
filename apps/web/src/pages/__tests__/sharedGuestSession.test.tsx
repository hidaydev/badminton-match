import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const shared = {
  session: {
    id: 's1',
    title: 'Tuesday Night',
    date: '2026-11-03',
    status: 'locked',
  },
  community: { slug: 'acme', name: 'Acme' },
  games: [
    {
      id: 'g1',
      round: 0,
      court: 0,
      sideA: ['Ani', 'Budi'],
      sideB: ['Candra', 'Dewi'],
      scoreA: 30,
      scoreB: 24,
      status: 'played',
    },
    {
      id: 'g2',
      round: 1,
      court: 0,
      sideA: ['Ani', 'Candra'],
      sideB: ['Budi', 'Dewi'],
      scoreA: 21,
      scoreB: 19,
      status: 'played',
    },
    {
      id: 'g3',
      round: 2,
      court: 0,
      sideA: ['Eka', 'Budi'],
      sideB: ['Candra', 'Dewi'],
      scoreA: null,
      scoreB: null,
      status: 'scheduled',
    },
  ],
}

function renderAt(path: string, body: unknown = shared) {
  mockFetch({
    'GET /api/auth/me': () => ({ status: 401, body: {} }),
    'GET /api/s/abc123': () => ({ body }),
  })
  window.history.replaceState({}, '', path)
  return render(<App />)
}

/** The row a played-toggle sits in: the only place the grid dims a game. */
function gameRow(label: string): HTMLElement {
  const toggle = screen.getByRole('button', { name: label })
  const row = toggle.parentElement
  if (row === null) throw new Error(`no row for ${label}`)
  return row
}

const G1 = 'Played: Ani & Budi vs Candra & Dewi'
const G2 = 'Played: Ani & Candra vs Budi & Dewi'
const G3 = 'Played: Eka & Budi vs Candra & Dewi'

describe('guest session page', () => {
  it('renders the internal body: one tab bar and the 3-column player list', async () => {
    renderAt('/s/abc123')

    expect(await screen.findByText('Tuesday Night')).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: t('summary.tab.schedule') })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: t('summary.tab.standings') })).toBeInTheDocument()

    const playerButtons = screen.getAllByRole('button', { name: /×/ })
    expect(playerButtons).toHaveLength(5)
    expect(playerButtons.map((button) => button.textContent?.replace(/×|\d+/g, ''))).toEqual(
      expect.arrayContaining(['Ani', 'Budi', 'Candra', 'Dewi', 'Eka']),
    )
    expect(playerButtons[0].parentElement?.className).toContain('grid-cols-3')
  })

  it('highlights only the tapped player’s games, and clears on a second tap', async () => {
    renderAt('/s/abc123')

    const ani = await screen.findByRole('button', { name: /^Ani/ })
    fireEvent.click(ani)

    // Ani plays g1 and g2; g3 does not feature her.
    expect(gameRow(G1).className).toContain('ring-yellow-400/40')
    expect(gameRow(G2).className).toContain('ring-yellow-400/40')
    expect(gameRow(G3).className).toContain('opacity-25')
    expect(gameRow(G3).className).not.toContain('ring-yellow-400/40')

    fireEvent.click(ani)

    expect(gameRow(G1).className).not.toContain('ring-yellow-400/40')
    expect(gameRow(G3).className).not.toContain('opacity-25')
  })

  it('offers no match sheet and no edit control', async () => {
    renderAt('/s/abc123')

    await screen.findByText('Tuesday Night')

    for (const label of [
      t('summary.finish'),
      t('summary.reopen'),
      t('summary.actions'),
      t('summary.delete'),
      t('session.share'),
    ]) {
      expect(screen.queryByText(label)).toBeNull()
    }
    // A locked grid keeps the played toggle visible but inert.
    expect(screen.getByRole('button', { name: G1 })).toBeDisabled()
    expect(screen.queryByRole('spinbutton')).toBeNull()
  })

  it('keeps standings rows read-only instead of opening the match sheet', async () => {
    renderAt('/s/abc123')

    await screen.findByText('Tuesday Night')
    fireEvent.click(screen.getByRole('tab', { name: t('summary.tab.standings') }))

    const list = screen.getByRole('list')
    const rows = within(list).getAllByRole('listitem')
    expect(rows.length).toBeGreaterThan(0)
    expect(within(list).queryAllByRole('button')).toHaveLength(0)
  })

  it('renders a payload with no session times on the 00:00 default', async () => {
    renderAt('/s/abc123')

    await screen.findByText('Tuesday Night')

    // Three rounds on one court, one hour apart, from a payload that carries
    // neither startTime nor slotMinutes.
    expect(screen.getByText('00:00')).toBeInTheDocument()
    expect(screen.getByText('01:00')).toBeInTheDocument()
    expect(screen.getByText('02:00')).toBeInTheDocument()
  })
})
