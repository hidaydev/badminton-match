import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { StandingsTable } from '../StandingsTable'
import type { StandingsRow } from '../StandingsTable'

const labels = { name: 'Player', winsLosses: 'W-L', diff: 'Diff', points: 'Pts' }

const rows: StandingsRow[] = [
  {
    key: 'a',
    rank: '1st',
    name: 'Ani',
    wins: 3,
    losses: 1,
    diff: 5,
    pointsFor: 61,
    onSelect: vi.fn(),
  },
  { key: 'b', rank: '2nd', name: 'Budi', wins: 1, losses: 3, diff: -3, pointsFor: 44 },
  { key: 'c', rank: '3rd', name: 'Citra', wins: 2, losses: 2, diff: 0, pointsFor: 52 },
  { key: 'd', rank: '4th', name: 'Dewi', wins: 4, losses: 0, diff: 9, pointsFor: 70 },
]

describe('StandingsTable', () => {
  it('renders the labels and one row per player', () => {
    render(<StandingsTable rows={rows} labels={labels} />)

    expect(screen.getByText('Player')).toBeInTheDocument()
    expect(screen.getByText('1st')).toBeInTheDocument()
    expect(screen.getByText('Ani')).toBeInTheDocument()
    expect(screen.getByText('4th')).toBeInTheDocument()
    expect(screen.getAllByRole('listitem')).toHaveLength(4)
  })

  it('renders the signed difference and leaves zero unsigned', () => {
    render(<StandingsTable rows={rows} labels={labels} />)

    expect(screen.getByText('+5')).toBeInTheDocument()
    expect(screen.getByText('-3')).toBeInTheDocument()
    expect(screen.getByText('0')).toBeInTheDocument()
    expect(screen.getByText('+9')).toBeInTheDocument()
    expect(screen.getByText('3-1')).toBeInTheDocument()
  })

  it('opens the row through its name button when a handler is given', () => {
    const onSelect = vi.fn()
    render(<StandingsTable rows={[{ ...rows[0], onSelect }]} labels={labels} />)

    fireEvent.click(screen.getByRole('button', { name: 'Ani' }))
    expect(onSelect).toHaveBeenCalledTimes(1)
  })

  it('renders a plain name when the row is not selectable', () => {
    render(<StandingsTable rows={[rows[1]]} labels={labels} />)

    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.getByText('Budi')).toBeInTheDocument()
  })

  it('prints a dash for zero in the compact group card and signs the rest', () => {
    render(
      <StandingsTable
        layout="compact"
        labels={{ wins: 'W', losses: 'L' }}
        rows={[
          { key: 'a', name: 'Ani', wins: 2, losses: 0, diff: 4, highlighted: true },
          { key: 'b', name: 'Budi', wins: 1, losses: 1, diff: 0, highlighted: true },
          { key: 'c', name: 'Citra', wins: 0, losses: 2, diff: -4 },
        ]}
      />,
    )

    expect(screen.getByText('+4')).toBeInTheDocument()
    expect(screen.getByText('—')).toBeInTheDocument()
    expect(screen.getByText('-4')).toBeInTheDocument()
  })

  it('renders the team ledger with points, record and for/against', () => {
    render(
      <StandingsTable
        layout="team"
        labels={{ pointsSuffix: 'pt' }}
        rows={[
          {
            key: 'a',
            rank: '👑',
            name: 'Tim Satu',
            points: 7,
            wins: 2,
            losses: 0,
            pointsFor: 61,
            pointsAgainst: 40,
            highlighted: true,
            details: <span>Aziz</span>,
          },
        ]}
      />,
    )

    expect(screen.getByText('7pt')).toBeInTheDocument()
    expect(screen.getByText('2-0')).toBeInTheDocument()
    expect(screen.getByText('61-40')).toBeInTheDocument()
    expect(screen.getByText('👑')).toBeInTheDocument()
    expect(screen.getByText('Aziz')).toBeInTheDocument()
  })

  it('renders the classic ledger with a stage line and a record pill', () => {
    render(
      <StandingsTable
        layout="record"
        labels={{ wins: 'W', losses: 'L' }}
        rows={[{ key: 'a', name: 'Ani & Budi', sublabel: 'Champion', wins: 3, losses: 1 }]}
      />,
    )

    expect(screen.getByText('Ani & Budi')).toBeInTheDocument()
    expect(screen.getByText('Champion')).toBeInTheDocument()
    expect(screen.getByText('3W')).toBeInTheDocument()
    expect(screen.getByText('1L')).toBeInTheDocument()
  })

  it('renders the rankings row with its movement cell and points', () => {
    const onSelect = vi.fn()
    render(
      <StandingsTable
        layout="rank"
        rows={[
          {
            key: 'a',
            rank: 1,
            rankDetail: 3,
            highlighted: true,
            name: 'Ani',
            nameExtra: <span>B</span>,
            delta: <span>▲</span>,
            pointsFor: 1240,
            onSelect,
          },
        ]}
      />,
    )

    expect(screen.getByText('#1')).toBeInTheDocument()
    expect(screen.getByText('#3')).toBeInTheDocument()
    expect(screen.getByText('▲')).toBeInTheDocument()
    expect(screen.getByText('1,240')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button'))
    expect(onSelect).toHaveBeenCalledTimes(1)
  })

  it('defaults every optional figure so a partial row still renders', () => {
    render(<StandingsTable rows={[{ key: 'a', name: 'Ani' }]} labels={labels} />)

    expect(screen.getByText('0-0')).toBeInTheDocument()
    // The difference and the points both print a zero on a row with no games.
    expect(screen.getAllByText('0')).toHaveLength(2)
  })

  it('renders the team ledger without a points pill value or a member line', () => {
    render(
      <StandingsTable
        layout="team"
        labels={{ pointsSuffix: 'pt' }}
        rows={[{ key: 'a', name: 'Tim Dua', pointsFor: 30 }]}
      />,
    )

    expect(screen.getByText('30pt')).toBeInTheDocument()
    expect(screen.getByText('0-0')).toBeInTheDocument()
    expect(screen.getByText('30-0')).toBeInTheDocument()
  })

  it('renders a rankings row that has no movement, no badge and no drill-in', () => {
    render(
      <StandingsTable layout="rank" rows={[{ key: 'a', rank: 4, name: 'Citra', pointsFor: 12 }]} />,
    )

    expect(screen.getByText('#4')).toBeInTheDocument()
    expect(screen.getByText('Citra')).toBeInTheDocument()
    expect(screen.getByText('12')).toBeInTheDocument()
  })

  it('refuses a layout whose words the caller did not supply', () => {
    // The primitive holds no UI string of its own (FE-13), so a missing label
    // is a wiring bug that fails loudly instead of rendering a blank header.
    expect(() => render(<StandingsTable rows={rows} />)).toThrow(/needs name/)
    expect(() => render(<StandingsTable layout="compact" rows={rows} />)).toThrow(/wins and losses/)
    expect(() => render(<StandingsTable layout="team" rows={rows} />)).toThrow(/pointsSuffix/)
    expect(() => render(<StandingsTable layout="record" rows={rows} />)).toThrow(/wins and losses/)
  })
})
