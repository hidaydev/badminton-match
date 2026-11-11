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
})
