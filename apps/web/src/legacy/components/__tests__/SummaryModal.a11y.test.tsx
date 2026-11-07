import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import SummaryModal from '../SummaryModal'
import { toPlayerId, type Player } from '../../types'

const players: Player[] = (
  [
    { id: 'p1', name: 'Ani', gender: 'F', tier: 3 },
    { id: 'p2', name: 'Budi', gender: 'M', tier: 3 },
    { id: 'p3', name: 'Candra', gender: 'M', tier: 3 },
    { id: 'p4', name: 'Dewi', gender: 'F', tier: 3 },
  ] as const
).map((p) => ({ ...p, id: toPlayerId(p.id) }))

const result = {
  schedule: [{ slot: 0, court: 0, teamA: ['p1', 'p2'].map(toPlayerId), teamB: ['p3', 'p4'].map(toPlayerId) }],
  playCount: {},
  sitCount: {},
  partnerWith: {},
  facedBy: {},
  unplacedFixMatches: [],
} as unknown as Parameters<typeof SummaryModal>[0]['result']

function renderModal(overrides: Record<string, unknown> = {}) {
  return render(
    <SummaryModal
      result={result}
      playerMap={new Map(players.map((p) => [p.id, p]))}
      slotsPerCourt={[1]}
      courtNames={['Court 1']}
      playedGames={[]}
      gameScores={{}}
      title="Test"
      date="2026-11-05"
      sessionStart="18:00"
      slotMinutes={20}
      courtTimes={[]}
      onClose={() => {}}
      {...overrides}
    />,
  )
}

describe('SummaryModal a11y wiring', () => {
  it('exposes the played toggle as a pressed button', () => {
    const onTogglePlayedGame = vi.fn()
    renderModal({ onTogglePlayedGame })
    const toggle = screen.getByRole('button', { name: /Played: Ani & Budi vs Candra & Dewi/ })
    expect(toggle).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(toggle)
    expect(onTogglePlayedGame).toHaveBeenCalledWith('0-0')
  })

  it('marks the schedule/standings strip as a tablist', () => {
    renderModal()
    const tabs = screen.getAllByRole('tab')
    expect(tabs.map((tab) => tab.textContent)).toEqual(['Schedule', 'Standings'])
    expect(tabs[0]).toHaveAttribute('aria-selected', 'true')
    fireEvent.click(tabs[1])
    expect(tabs[1]).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tabpanel')).toBeInTheDocument()
  })

  it('moves focus into the dialog and keeps Escape closing it', () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    expect(screen.getByRole('dialog')).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalled()
  })

  it('shows the points, not the set count, in a single-set format', () => {
    renderModal({
      playedGames: ['0-0'],
      gameScores: { '0-0': { a: 24, b: 30, sets: [{ a: 24, b: 30 }] } },
      scoring: {
        preset: 'legacy_v1',
        label: 'v1 scoring',
        gamesToWin: 1,
        pointsToWin: 30,
        winBy: 1,
        maxPoints: 99,
        deuceAt: null,
        changeEndsAt: 15,
      },
    })

    expect(screen.getByRole('button', { name: /Score:.*24–30/ })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Score:.*0–1/ })).toBeNull()
  })

  it('shows the set count in a best-of-three format', () => {
    renderModal({
      playedGames: ['0-0'],
      gameScores: {
        '0-0': { a: 51, b: 40, sets: [{ a: 30, b: 28 }, { a: 21, b: 12 }] },
      },
      scoring: {
        preset: 'classic21',
        label: 'Classic BO3 21',
        gamesToWin: 2,
        pointsToWin: 21,
        winBy: 2,
        maxPoints: 30,
        deuceAt: 20,
        changeEndsAt: 11,
      },
    })

    expect(screen.getByRole('button', { name: /Score:.*2–0/ })).toBeInTheDocument()
  })
})