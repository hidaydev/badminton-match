import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import type { CommunityRole, Membership } from '../../auth/api'
import { jsonBody, mockFetch } from '../../test/fetchMock'
import type { Handler } from '../../test/fetchMock'
import type { TeamInfo, TeamPartai, TeamSnapshot } from '../types'
import { TEAM_CLASSES, TEAM_NAMES, drawGroupMatches } from '../team/rules'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

function membership(role: CommunityRole): Membership {
  return { id: 'c1', slug: 'acme', name: 'Acme', role }
}

const teams: TeamInfo[] = TEAM_NAMES.map((name, index) => ({
  id: `t${index + 1}`,
  name,
  players: TEAM_CLASSES.map((cls) => ({ name: `${name} ${cls}`, cls })),
}))

/** Nine drawn matches; the first three carry results so the table is not empty. */
function baseSnapshot(): TeamSnapshot {
  const matches = drawGroupMatches(teams.map((team) => team.id))
  matches[0] = {
    ...matches[0],
    partai: [
      { scoreA: 30, scoreB: 10 },
      { scoreA: 30, scoreB: 12 },
      { scoreA: 30, scoreB: 14 },
    ],
  }
  matches[1] = {
    ...matches[1],
    partai: [
      { scoreA: 30, scoreB: 20 },
      { scoreA: 20, scoreB: 30 },
      { scoreA: 30, scoreB: 25 },
    ],
  }
  matches[2] = {
    ...matches[2],
    partai: [
      { scoreA: 20, scoreB: 30 },
      { scoreA: 30, scoreB: 20 },
      { scoreA: 25, scoreB: 30 },
    ],
  }
  return {
    id: 'tr1',
    version: 1,
    format: 'team',
    name: 'Friday Night',
    date: '2026-11-06',
    teams,
    matches,
  }
}

function sessionHandlers(role: CommunityRole) {
  return {
    'GET /api/auth/me': () => ({ body: sessionUser }),
    'GET /api/communities': () => ({ body: { items: [membership(role)] } }),
  }
}

function renderPage(
  role: CommunityRole = 'member',
  handlers: Record<string, Handler> = {},
) {
  mockFetch({
    ...sessionHandlers(role),
    'GET /api/c/acme/tournaments/tr1': () => ({ body: baseSnapshot() }),
    ...handlers,
  })
  window.history.replaceState({}, '', '/c/acme/tournaments/team/tr1')
  return render(<App />)
}

function partaiLabel(index: number, teamName: string): string {
  return `${t('team.partai', { index })} ${teamName}`
}

async function scorePartai(
  card: HTMLElement,
  index: number,
  teamA: string,
  teamB: string,
  scoreA: string,
  scoreB: string,
) {
  fireEvent.change(within(card).getByLabelText(partaiLabel(index, teamA)), {
    target: { value: scoreA },
  })
  fireEvent.change(within(card).getByLabelText(partaiLabel(index, teamB)), {
    target: { value: scoreB },
  })
}

describe('TournamentTeamPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('renders the roster form for a new team tournament', async () => {
    mockFetch(sessionHandlers('admin'))
    window.history.replaceState({}, '', '/c/acme/tournaments/team/new')
    render(<App />)

    expect(
      await screen.findByRole('heading', { name: t('tournaments.newTeam') }),
    ).toBeInTheDocument()
    expect(screen.getByLabelText(t('tournament.name'))).toBeInTheDocument()
    expect(screen.getByLabelText(t('tournament.date'))).toBeInTheDocument()
    // One name field per class for each of the six canonical teams.
    expect(screen.getAllByLabelText(`${t('team.player')} · A+`)).toHaveLength(6)
    expect(screen.getAllByLabelText(`${t('team.player')} · C`)).toHaveLength(6)
    // The fixed nine-match draw is previewed before saving.
    const preview = screen.getAllByRole('listitem')
    expect(preview).toHaveLength(9)
    expect(preview[0]).toHaveTextContent(t('team.target', { score: 30 }))
  })

  it('renders the schedule and the standings from the API snapshot', async () => {    renderPage()

    expect(
      await screen.findByRole('heading', { name: 'Friday Night' }),
    ).toBeInTheDocument()

    // Nine group team-matches, each one target-30 and partai class labelled.
    expect(screen.getAllByText(t('team.target', { score: 30 }))).toHaveLength(9)
    expect(screen.getAllByText('Partai 1 · C+ / C')).toHaveLength(9)
    expect(screen.getAllByText('Partai 2 · A+ / A')).toHaveLength(9)
    expect(screen.getAllByText('Partai 3 · B+ / B')).toHaveLength(9)
    expect(screen.getByText(t('classic.tbd'))).toBeInTheDocument()

    const table = screen.getByRole('table', { name: t('team.standings') })
    const red = within(table).getByRole('row', { name: /RED RAPTORS/ })
    expect(
      within(red)
        .getAllByRole('cell')
        .map((cell) => cell.textContent),
    ).toEqual(['1', '3', '0', '3', '54'])
  })

  it('patches one partai with If-Match and moves the version', async () => {
    const patches: { body: unknown; ifMatch: string | null }[] = []
    let version = 1

    const applyPatch = (init: RequestInit | undefined): TeamSnapshot => {
      const body = jsonBody(init) as { partai: TeamPartai[] }
      version += 1
      const snapshot = baseSnapshot()
      return {
        ...snapshot,
        version,
        matches: snapshot.matches.map((match) =>
          match.id === 'g-1' ? { ...match, partai: body.partai } : match,
        ),
      }
    }

    renderPage('member', {
      'PATCH /api/c/acme/tournaments/tr1/matches/g-1': (init) => {
        patches.push({
          body: jsonBody(init),
          ifMatch: new Headers(init?.headers).get('If-Match'),
        })
        return { body: applyPatch(init) }
      },
    })

    const card = await screen.findByRole('article', {
      name: 'RED RAPTORS — WHITE FURY',
    })
    await scorePartai(card, 1, 'RED RAPTORS', 'WHITE FURY', '21', '15')
    fireEvent.click(within(card).getByRole('button', { name: t('tournament.save') }))

    await waitFor(() => expect(patches).toHaveLength(1))
    expect(patches[0]).toEqual({
      body: {
        partai: [
          { scoreA: 21, scoreB: 15 },
          { scoreA: 30, scoreB: 12 },
          { scoreA: 30, scoreB: 14 },
        ],
      },
      ifMatch: '"1"',
    })
    expect(await screen.findByText(t('tournament.saved'))).toBeInTheDocument()

    // The saved snapshot (version 2) remounts the card; the next save uses it.
    const remounted = screen.getByRole('article', {
      name: 'RED RAPTORS — WHITE FURY',
    })
    await scorePartai(remounted, 2, 'RED RAPTORS', 'WHITE FURY', '18', '16')
    fireEvent.click(
      within(remounted).getByRole('button', { name: t('tournament.save') }),
    )

    await waitFor(() => expect(patches).toHaveLength(2))
    expect(patches[1]).toEqual({
      body: {
        partai: [
          { scoreA: 21, scoreB: 15 },
          { scoreA: 18, scoreB: 16 },
          { scoreA: 30, scoreB: 14 },
        ],
      },
      ifMatch: '"2"',
    })
  })

  it('shows the conflict message when the version is stale', async () => {
    renderPage('member', {
      'PATCH /api/c/acme/tournaments/tr1/matches/g-1': () => ({
        status: 412,
        body: { code: 'STALE' },
      }),
    })

    const card = await screen.findByRole('article', {
      name: 'RED RAPTORS — WHITE FURY',
    })
    await scorePartai(card, 1, 'RED RAPTORS', 'WHITE FURY', '21', '15')
    fireEvent.click(within(card).getByRole('button', { name: t('tournament.save') }))

    expect(
      await screen.findByText(t('tournament.error.conflict')),
    ).toBeInTheDocument()
  })

  it('creates the final between the top two teams with a full replace', async () => {
    const decided = baseSnapshot()
    const sweep: [number, number][] = [
      [30, 10],
      [30, 10],
      [30, 10],
    ]
    for (let index = 3; index < decided.matches.length; index += 1) {
      decided.matches[index] = {
        ...decided.matches[index],
        partai: sweep.map(([scoreA, scoreB]) => ({ scoreA, scoreB })),
      }
    }

    let replaced: TeamSnapshot | null = null
    renderPage('member', {
      'GET /api/c/acme/tournaments/tr1': () => ({ body: decided }),
      'PUT /api/c/acme/tournaments/tr1': (init) => {
        replaced = jsonBody(init) as TeamSnapshot
        return { body: { ...replaced, version: 2 } }
      },
    })

    expect(
      await screen.findByRole('heading', { name: 'Friday Night' }),
    ).toBeInTheDocument()
    fireEvent.click(
      await screen.findByRole('button', { name: t('team.createFinal') }),
    )

    await waitFor(() => expect(replaced).not.toBeNull())
    const body = replaced as unknown as TeamSnapshot
    expect(body.matches).toHaveLength(10)
    expect(body.matches[9]).toMatchObject({
      id: 'final',
      phase: 'final',
      teamA: 't1',
      teamB: 't2',
    })
    expect(await screen.findByText(t('team.target', { score: 42 }))).toBeInTheDocument()
  })

  it('hides the rating actions from a non-admin membership', async () => {
    renderPage('member')

    expect(
      await screen.findByRole('heading', { name: 'Friday Night' }),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: t('team.rating.finalize') }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: t('team.rating.ingest') }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: t('tournaments.delete') }),
    ).not.toBeInTheDocument()
  })

  it('shows the rating actions to an admin membership', async () => {
    renderPage('admin')

    expect(
      await screen.findByRole('heading', { name: 'Friday Night' }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: t('team.rating.finalize') }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: t('team.rating.ingest') }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: t('team.rating.revert') }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: t('tournaments.delete') }),
    ).toBeInTheDocument()
  })
})
