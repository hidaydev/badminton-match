// The grid used to be a state channel: 38 props, twelve of them setters and
// callbacks, so it could not be rendered without wiring an editor. These tests
// pin the read-only contract: data, mode, locked and saving are enough.
import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import ScheduleGrid, { type ScheduleGridData } from './ScheduleGrid'
import type { PlayerChipMode } from './PlayerChipRenderer'
import { toPlayerId, type Player, type PlayerId } from '../../types'

const players: Player[] = (
  [
    { id: 'p1', name: 'Ani', gender: 'F', tier: 3 },
    { id: 'p2', name: 'Budi', gender: 'M', tier: 3 },
    { id: 'p3', name: 'Candra', gender: 'M', tier: 3 },
    { id: 'p4', name: 'Dewi', gender: 'F', tier: 3 },
  ] as const
).map((p) => ({ ...p, id: toPlayerId(p.id) }))

function makeData(overrides: Partial<ScheduleGridData> = {}): ScheduleGridData {
  return {
    result: {
      schedule: [{ slot: 0, court: 0, teamA: ['p1', 'p2'].map(toPlayerId), teamB: ['p3', 'p4'].map(toPlayerId) }],
      playCount: {},
      sitCount: {},
      partnerWith: {},
      facedBy: {},
      unplacedFixMatches: [],
    },
    slotsPerCourt: [1],
    courtNames: ['Court 1'],
    sessionStart: '18:00',
    slotMinutes: 20,
    playerMap: new Map(players.map((p) => [p.id, p])),
    playedGames: [],
    gameScores: {},
    effectiveAbsent: new Set<string>(),
    effectiveSkipped: {},
    highlightedPlayerId: null,
    ...overrides,
  } as ScheduleGridData
}

describe('ScheduleGrid read-only render', () => {
  it('draws the schedule from data alone, with no interaction channel', () => {
    render(<ScheduleGrid data={makeData()} mode="idle" locked saving={false} />)

    expect(screen.getByText('Court 1')).toBeInTheDocument()
    expect(screen.getByText('Ani')).toBeInTheDocument()
    expect(screen.getByText('Dewi')).toBeInTheDocument()
  })

  it('offers no score editor and no played toggle in a locked view', () => {
    render(<ScheduleGrid data={makeData()} mode="idle" locked saving={false} />)

    expect(screen.queryByRole('button', { name: '+ score' })).toBeNull()
    expect(screen.getByRole('button', { name: /Played:/ })).toBeDisabled()
  })

  it('renders a saved score as text when there is nothing to edit with', () => {
    render(
      <ScheduleGrid
        data={makeData({ gameScores: { '0-0': { a: 21, b: 15, sets: [{ a: 21, b: 15 }] } } })}
        mode="idle"
        locked
        saving={false}
      />,
    )

    expect(screen.getByRole('button', { name: /Score:.*21–15/ })).toBeInTheDocument()
    expect(screen.queryByRole('spinbutton')).toBeNull()
  })

  it.each<PlayerChipMode>(['swap', 'teamSwap', 'replace', 'skip', 'change', 'slotSwap'])(
    'renders the %s mode without interaction state or handlers',
    (mode) => {
      render(<ScheduleGrid data={makeData()} mode={mode} locked={false} saving={false} />)

      expect(screen.getByText('Ani')).toBeInTheDocument()
      expect(screen.getByText('Candra')).toBeInTheDocument()
    },
  )

  // A pair that truncates per name reads "Ca… & De…", which names nobody. The
  // idle row has no tap target per name, so it is allowed to cut the pair once:
  // one ellipsis, after the last name.
  it('cuts an idle pair once, at the end, instead of clipping each name', () => {
    const { container } = render(
      <ScheduleGrid data={makeData()} mode="idle" locked saving={false} />,
    )

    const teamCells = Array.from(
      container.querySelectorAll('[style*="grid-template-columns"] > div'),
    )
    expect(teamCells).toHaveLength(2)
    for (const cell of teamCells) {
      // The pair line itself is the one clamp; no leaf is cut on its own.
      expect(cell.className).toContain('truncate')
      expect(cell.querySelectorAll('.truncate')).toHaveLength(0)
      // Each leaf stays on one line, so the cut happens at the pair's end.
      expect(cell.querySelectorAll('.whitespace-nowrap')).toHaveLength(2)
    }
  })

  // The court label used to own a fixed 32-40px track. It is content-sized now:
  // a long custom name may not push the pair names, and the full value stays
  // reachable through the title.
  it('keeps a long court name out of the names, with the full value in its title', () => {
    render(
      <ScheduleGrid
        data={makeData({ courtNames: ['Court One — East Wing Championship Deck'] })}
        mode="idle"
        locked
        saving={false}
      />,
    )

    const label = screen.getByTitle('Court One — East Wing Championship Deck')
    expect(label).toBeInTheDocument()
    expect(label.className).toContain('truncate')
    expect(label.className).toContain('max-w-12')
    // Short enough that the pair never inherits the label's width.
    expect(label.className).toContain('min-w-0')
    // The pair is still the cell next to it, not pushed out of the row.
    expect(screen.getByText('Ani')).toBeInTheDocument()
  })

  // The spacing between the names is `gap-1` in the flex modes and `mx-1` on the
  // ampersand in the inline one, so the pair reads identically either way.
  it('keeps the same 4px around the ampersand in the inline pair', () => {
    const { container } = render(
      <ScheduleGrid data={makeData()} mode="idle" locked saving={false} />,
    )

    const ampersands = Array.from(container.querySelectorAll('[style*="grid-template-columns"] span'))
      .filter((el) => el.textContent === '&')
    expect(ampersands).toHaveLength(2)
    for (const el of ampersands) expect(el.className).toContain('mx-1')
  })

  // A saved session can carry a stale origin: the court hours were edited to
  // 19:00 before the store learned to move `sessionStart` with them, so the
  // generator placed the first game at slot 30. The grid drew ten hours of empty
  // rows above it, which read as a broken schedule rather than a late start.
  it('starts at the first played slot instead of drawing the rows above it', () => {
    render(
      <ScheduleGrid
        data={makeData({
          sessionStart: '09:00',
          slotsPerCourt: [31],
          result: {
            schedule: [
              { slot: 30, court: 0, teamA: ['p1', 'p2'].map(toPlayerId) as [PlayerId, PlayerId], teamB: ['p3', 'p4'].map(toPlayerId) as [PlayerId, PlayerId] },
            ],
            playCount: {},
            sitCount: {},
            partnerWith: {},
            facedBy: {},
            unplacedFixMatches: [],
          },
        })}
        mode="idle"
        locked
        saving={false}
      />,
    )

    // Slot 30 on a 09:00 origin is 19:00; the row number follows the screen.
    expect(screen.getByText('#1')).toBeInTheDocument()
    expect(screen.queryByText('#2')).toBeNull()
    expect(screen.getByText('19:00')).toBeInTheDocument()
    expect(screen.queryByText('09:00')).toBeNull()
    expect(screen.getByText('Ani')).toBeInTheDocument()
  })
})
