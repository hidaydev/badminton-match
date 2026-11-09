import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import SummaryModal from '../SummaryModal'
import { ApiError } from '../../queries/endpoints'
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
      {...overrides}
    />,
  )
}

function enterScore(): void {
  fireEvent.click(screen.getByRole('button', { name: '+ score' }))
  const inputs = screen.getAllByRole('spinbutton')
  fireEvent.change(inputs[0], { target: { value: '21' } })
  fireEvent.change(inputs[1], { target: { value: '15' } })
  fireEvent.click(screen.getByRole('button', { name: /Save/ }))
}

describe('SummaryModal failed score writes', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps a failed score attached to its game until it is retried', async () => {
    const onSetGameScore = vi
      .fn()
      .mockRejectedValueOnce(new ApiError('being updated by another request', '55P03', 429))
      .mockResolvedValueOnce(undefined)

    renderModal({ onSetGameScore })
    enterScore()

    expect(await screen.findByText(/Score not saved/)).toBeInTheDocument()
    expect(onSetGameScore).toHaveBeenCalledWith('0-0', [{ a: 21, b: 15 }])

    // A success acknowledgement may time out; a failure may not.
    vi.useFakeTimers()
    act(() => {
      vi.advanceTimersByTime(10_000)
    })
    expect(screen.getByText(/Score not saved/)).toBeInTheDocument()
    vi.useRealTimers()

    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))

    await waitFor(() => expect(screen.queryByText(/Score not saved/)).toBeNull())
    expect(onSetGameScore).toHaveBeenCalledTimes(2)
    expect(onSetGameScore).toHaveBeenLastCalledWith('0-0', [{ a: 21, b: 15 }])
  })

  it('lets the user dismiss the failure instead of silently clearing it', async () => {
    const onSetGameScore = vi.fn().mockRejectedValue(new ApiError('offline', null, null))

    renderModal({ onSetGameScore })
    enterScore()

    expect(await screen.findByText(/Score not saved/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Dismiss score error/ }))

    expect(screen.queryByText(/Score not saved/)).toBeNull()
  })
})
