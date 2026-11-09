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

    const points = screen.getByText('21–18 · 19–21')
    const tally = screen.getByText('1 - 1')
    expect(points).toHaveClass('text-sm', 'text-slate-300')
    expect(tally).toHaveClass('text-[11px]', 'text-slate-400')
    expect(points.compareDocumentPosition(tally) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('keeps the plain score for a game without recorded sets', () => {
    renderSheet('Ani', {
      [toGameKey(0, 0)]: { a: 21, b: 15 },
    })

    expect(screen.getByText('21–15')).toBeInTheDocument()
  })

  it('orients the points and the tally to a winning team B player', () => {
    renderSheet('Candra', {
      [toGameKey(0, 0)]: { a: 18, b: 21, sets: [{ a: 18, b: 21 }] },
    })

    expect(screen.getByText('21–18')).toBeInTheDocument()
    expect(screen.queryByText('18–21')).toBeNull()
    expect(badge('Won', 'text-emerald-400')).toBeDefined()
  })

  it('orients the points and the badge to a losing team B player', () => {
    renderSheet('Candra', {
      [toGameKey(0, 0)]: { a: 21, b: 18, sets: [{ a: 21, b: 18 }] },
    })

    expect(screen.getByText('18–21')).toBeInTheDocument()
    expect(badge('Lost', 'text-red-400')).toBeDefined()
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
