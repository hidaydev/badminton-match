import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'
import { generateTournament, propagateBracket } from '../classic/draw'
import type { ClassicMatch, ClassicSnapshot, Pair } from '../types'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

const sessionHandlers = {
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items: [acme] } }),
}

function pairs(): Pair[] {
  return Array.from({ length: 16 }, (_, index) => ({
    id: `p${index + 1}`,
    name: `Pair ${index + 1}`,
  }))
}

function withScore(
  snapshot: ClassicSnapshot,
  id: string,
  scoreA: number | null,
  scoreB: number | null,
): ClassicSnapshot {
  const matches = snapshot.matches.map((match) =>
    match.id === id ? { ...match, scoreA, scoreB } : match,
  )
  return { ...snapshot, matches: propagateBracket(matches, snapshot.groups) }
}

/** A played bracket so the final and third-place rows have both pairs set. */
function playedSnapshot(): ClassicSnapshot {
  let snapshot = generateTournament('Cup', '2026-11-04', pairs(), 11)
  for (const [index, id] of ['qf-1', 'qf-2', 'qf-3', 'qf-4'].entries()) {
    snapshot = withScore(snapshot, id, 21, 10 + index)
  }
  snapshot = withScore(snapshot, 'sf-1', 21, 11)
  snapshot = withScore(snapshot, 'sf-2', 21, 12)
  return { ...snapshot, id: 't1', version: 1 }
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

function ifMatch(init: RequestInit | undefined): string | null {
  return new Headers(init?.headers ?? {}).get('If-Match')
}

function matchOf(snapshot: ClassicSnapshot, id: string): ClassicMatch {
  const match = snapshot.matches.find((candidate) => candidate.id === id)
  if (match === undefined) throw new Error(`missing match ${id}`)
  return match
}

function namesOf(snapshot: ClassicSnapshot): Map<string, string> {
  return new Map(snapshot.pairs.map((pair) => [pair.id, pair.name]))
}

function rowFor(label: string) {
  return screen.getByRole('group', { name: label })
}

function scoreLabel(matchLabel: string, name: string): string {
  return `${matchLabel} · ${t('classic.score')} ${name}`
}

describe('TournamentClassicPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('renders standings and the bracket from the loaded snapshot', async () => {
    const stored = playedSnapshot()
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/tournaments/t1': () => ({ body: stored }),
    })

    renderAt('/c/acme/tournaments/classic/t1')

    expect(await screen.findByRole('heading', { name: 'Cup' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: t('classic.groups') })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: t('classic.bracket') })).toBeInTheDocument()
    for (const group of ['A', 'B', 'C', 'D']) {
      expect(
        screen.getByRole('heading', { name: t('classic.group', { group }) }),
      ).toBeInTheDocument()
    }
    expect(
      screen.getByRole('heading', { name: t('classic.phase.qf') }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('heading', { name: t('classic.phase.final') }),
    ).toBeInTheDocument()

    // Standings list every pair in the group.
    for (const pairId of stored.groups.A) {
      expect(screen.getAllByText(namesOf(stored).get(pairId)!).length).toBeGreaterThan(0)
    }
  })

  it('saves one match with PATCH, carries the new version into the next If-Match', async () => {
    const stored = playedSnapshot()
    const names = namesOf(stored)
    let current = stored

    const finalPairA = stored.matches
      .find((match) => match.id === 'final-1')!
      .pairAId!
    const thirdPairA = stored.matches
      .find((match) => match.id === '3rd-1')!
      .pairAId!

    const fetchMock = mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/tournaments/t1': () => ({ body: stored }),
      'PATCH /api/c/acme/tournaments/t1/matches/final-1': (init) => {
        const body = jsonBody(init) as { scoreA: number; scoreB: number }
        current = withScore({ ...current, version: 2 }, 'final-1', body.scoreA, body.scoreB)
        return { body: current }
      },
      'PATCH /api/c/acme/tournaments/t1/matches/3rd-1': (init) => {
        const body = jsonBody(init) as { scoreA: number; scoreB: number }
        current = withScore({ ...current, version: 3 }, '3rd-1', body.scoreA, body.scoreB)
        return { body: current }
      },
    })

    renderAt('/c/acme/tournaments/classic/t1')
    await screen.findByRole('heading', { name: 'Cup' })

    const finalLabel = `${t('classic.phase.final')} 1`
    const finalRow = rowFor(finalLabel)
    fireEvent.change(
      within(finalRow).getByLabelText(scoreLabel(finalLabel, names.get(finalPairA)!)),
      { target: { value: '21' } },
    )
    fireEvent.change(
      within(finalRow).getByLabelText(
        scoreLabel(finalLabel, names.get(matchOf(stored, 'final-1').pairBId!)!),
      ),
      { target: { value: '18' } },
    )
    fireEvent.click(within(finalRow).getByRole('button', { name: t('tournament.save') }))

    expect(await within(finalRow).findByText(t('tournament.saved'))).toBeInTheDocument()

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) => String(url).includes('/matches/')),
      ).toHaveLength(1)
    })

    const thirdLabel = `${t('classic.phase.3rd')} 1`
    const thirdRow = rowFor(thirdLabel)
    fireEvent.change(
      within(thirdRow).getByLabelText(scoreLabel(thirdLabel, names.get(thirdPairA)!)),
      { target: { value: '21' } },
    )
    fireEvent.change(
      within(thirdRow).getByLabelText(
        scoreLabel(thirdLabel, names.get(matchOf(stored, '3rd-1').pairBId!)!),
      ),
      { target: { value: '19' } },
    )
    fireEvent.click(within(thirdRow).getByRole('button', { name: t('tournament.save') }))

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) => String(url).includes('/matches/')),
      ).toHaveLength(2)
    })

    const patchCalls = fetchMock.mock.calls.filter(([url]) =>
      String(url).includes('/matches/'),
    )
    expect(String(patchCalls[0][0])).toBe('/api/c/acme/tournaments/t1/matches/final-1')
    expect(ifMatch(patchCalls[0][1])).toBe('"1"')
    expect(jsonBody(patchCalls[0][1])).toEqual({ scoreA: 21, scoreB: 18 })

    expect(String(patchCalls[1][0])).toBe('/api/c/acme/tournaments/t1/matches/3rd-1')
    expect(ifMatch(patchCalls[1][1])).toBe('"2"')
    expect(jsonBody(patchCalls[1][1])).toEqual({ scoreA: 21, scoreB: 19 })
  })

  it('shows the conflict message on a 412', async () => {
    const stored = playedSnapshot()
    const names = namesOf(stored)
    const finalLabel = `${t('classic.phase.final')} 1`
    const pairA = matchOf(stored, 'final-1').pairAId!

    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/tournaments/t1': () => ({ body: stored }),
      'PATCH /api/c/acme/tournaments/t1/matches/final-1': () => ({
        status: 412,
        body: { code: 'STALE_VERSION' },
      }),
    })

    renderAt('/c/acme/tournaments/classic/t1')
    await screen.findByRole('heading', { name: 'Cup' })

    const finalRow = rowFor(finalLabel)
    fireEvent.change(
      within(finalRow).getByLabelText(scoreLabel(finalLabel, names.get(pairA)!)),
      { target: { value: '21' } },
    )
    fireEvent.change(
      within(finalRow).getByLabelText(
        scoreLabel(finalLabel, names.get(matchOf(stored, 'final-1').pairBId!)!),
      ),
      { target: { value: '15' } },
    )
    fireEvent.click(within(finalRow).getByRole('button', { name: t('tournament.save') }))

    expect(await within(finalRow).findByText(t('tournament.error.conflict'))).toBeInTheDocument()
  })

  it('persists the propagated bracket after a group score changed the seeding', async () => {
    const stored = { ...generateTournament('Cup', '2026-11-04', pairs(), 11), id: 't1', version: 1 }
    const groupMatch = matchOf(stored, 'group-A-0')
    const groupLabel = `${t('classic.group', { group: 'A' })} · ${t('classic.match')} 1`

    const fetchMock = mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/tournaments/t1': () => ({ body: stored }),
      'PATCH /api/c/acme/tournaments/t1/matches/group-A-0': (init) => {
        const body = jsonBody(init) as { scoreA: number; scoreB: number }
        // The API patches exactly one row: no bracket propagation server-side.
        return {
          body: {
            ...stored,
            version: 2,
            matches: stored.matches.map((match) =>
              match.id === 'group-A-0'
                ? { ...match, scoreA: body.scoreA, scoreB: body.scoreB }
                : match,
            ),
          },
        }
      },
      'PUT /api/c/acme/tournaments/t1': (init) => {
        const body = jsonBody(init) as ClassicSnapshot
        return { body: { ...body, version: 3 } }
      },
    })

    renderAt('/c/acme/tournaments/classic/t1')
    await screen.findByRole('heading', { name: 'Cup' })

    const row = rowFor(groupLabel)
    fireEvent.change(
      within(row).getByLabelText(
        scoreLabel(groupLabel, namesOf(stored).get(groupMatch.pairAId!)!),
      ),
      { target: { value: '10' } },
    )
    fireEvent.change(
      within(row).getByLabelText(
        scoreLabel(groupLabel, namesOf(stored).get(groupMatch.pairBId!)!),
      ),
      { target: { value: '21' } },
    )
    fireEvent.click(within(row).getByRole('button', { name: t('tournament.save') }))

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(([url]) =>
          String(url) === '/api/c/acme/tournaments/t1',
        ).some(([, init]) => init?.method === 'PUT'),
      ).toBe(true)
    })

    const put = fetchMock.mock.calls.find(
      ([url, init]) => String(url) === '/api/c/acme/tournaments/t1' && init?.method === 'PUT',
    )!
    expect(ifMatch(put[1])).toBe('"2"')
    const body = jsonBody(put[1]) as ClassicSnapshot
    const quarterfinal = body.matches.find((match) => match.id === 'qf-1')!
    // The group winner moves into the A1 slot, so qf-1's first pair follows the
    // new standings instead of the draw order.
    expect(quarterfinal.pairAId).toBe(groupMatch.pairBId)
    expect(quarterfinal.pairAId).not.toBe(groupMatch.pairAId)
  })
})
