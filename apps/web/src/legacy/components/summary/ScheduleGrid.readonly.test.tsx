// The grid used to be a state channel: 38 props, twelve of them setters and
// callbacks, so it could not be rendered without wiring an editor. These tests
// pin the read-only contract: data, mode, locked and saving are enough.
import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import ScheduleGrid, { type ScheduleGridData } from './ScheduleGrid'
import type { PlayerChipMode } from './PlayerChipRenderer'
import { toPlayerId, type Player } from '../../types'

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
})
