import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import PlayerMatchDetailSheet from './PlayerMatchDetailSheet'
import { toPlayerId, toGameKey, type Player, type ScheduleSlot, type GameScore } from '../../types'
import type { PlayerStanding } from '../../utils/standings'

const players: Player[] = (
  [
    { id: 'p1', name: 'Ani', gender: 'F', tier: 3 },
    { id: 'p2', name: 'Budi', gender: 'M', tier: 3 },
    { id: 'p3', name: 'Candra', gender: 'M', tier: 3 },
    { id: 'p4', name: 'Dewi', gender: 'F', tier: 3 },
  ] as const
).map((p) => ({ ...p, id: toPlayerId(p.id) }))

const schedule: ScheduleSlot[] = [
  {
    slot: 0,
    court: 0,
    teamA: [toPlayerId('p1'), toPlayerId('p2')],
    teamB: [toPlayerId('p3'), toPlayerId('p4')],
  },
]

function standingFor(name: string): PlayerStanding {
  const player = players.find((p) => p.name === name)
  if (!player) throw new Error(`unknown player ${name}`)
  return { player, wins: 1, losses: 0, pointsFor: 0, pointsAgainst: 0, diff: 0 }
}

function renderSheet(name: string, scores: Record<string, GameScore>) {
  return render(
    <PlayerMatchDetailSheet
      player={standingFor(name)}
      rank={1}
      schedule={schedule}
      gameScores={scores}
      players={players}
      onClose={() => {}}
    />,
  )
}

function badge(label: 'Won' | 'Lost', tone: 'text-emerald-400' | 'text-red-400') {
  return screen.getAllByText(label).find((el) => el.className.includes(tone))
}

describe('PlayerMatchDetailSheet match history', () => {
  it('shows the points, not only the set tally, for a single set', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: { a: 21, b: 18, sets: [{ a: 21, b: 18 }] },
    })

    expect(screen.getByText('21–18')).toBeInTheDocument()
    expect(screen.queryByText('1 - 0')).toBeNull()
  })

  it('shows every set score for a multi-set match, with the tally as secondary text', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: {
        a: 40,
        b: 39,
        sets: [
          { a: 21, b: 18 },
          { a: 19, b: 21 },
        ],
      },
    })

    expect(screen.getByText('21–18 · 19–21')).toBeInTheDocument()
    expect(screen.getByText('1 - 1')).toBeInTheDocument()
  })

  it('keeps the plain score for a game without recorded sets', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: { a: 21, b: 15 },
    })

    expect(screen.getByText('21 - 15')).toBeInTheDocument()
  })

  it('still shows the Won badge for a winning match', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: { a: 21, b: 18, sets: [{ a: 21, b: 18 }] },
    })

    expect(badge('Won', 'text-emerald-400')).toBeDefined()
  })

  it('still shows the Lost badge for a losing match', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: { a: 10, b: 21 },
    })

    expect(badge('Lost', 'text-red-400')).toBeDefined()
  })
})
