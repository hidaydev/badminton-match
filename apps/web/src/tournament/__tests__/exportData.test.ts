import { describe, expect, it } from 'vitest'
import {
  classicBracketRows,
  classicGroupRows,
  teamFinalExport,
  teamStandingRows,
} from '../export'
import type { ClassicMatch, ClassicSnapshot, TeamMatch, TeamSnapshot } from '../types'

function classicSnapshot(): ClassicSnapshot {
  const matches: ClassicMatch[] = [
    {
      id: 'group-A-0',
      phase: 'group',
      groupId: 'A',
      pairAId: 'p1',
      pairBId: 'p2',
      scoreA: 30,
      scoreB: 20,
    },
    {
      id: 'group-A-1',
      phase: 'group',
      groupId: 'A',
      pairAId: 'p3',
      pairBId: 'p4',
      scoreA: 30,
      scoreB: 25,
    },
    {
      id: 'group-A-2',
      phase: 'group',
      groupId: 'A',
      pairAId: 'p2',
      pairBId: 'p3',
      scoreA: 18,
      scoreB: 30,
    },
    {
      id: 'qf-1',
      phase: 'qf',
      groupId: null,
      pairAId: 'p1',
      pairBId: 'p4',
      scoreA: 30,
      scoreB: 22,
    },
    {
      id: 'qf-2',
      phase: 'qf',
      groupId: null,
      pairAId: null,
      pairBId: null,
      scoreA: null,
      scoreB: null,
    },
  ]
  return {
    format: 'classic',
    name: 'Classic Cup',
    date: '2026-11-04',
    pairs: [
      { id: 'p1', name: 'Ani & Budi' },
      { id: 'p2', name: 'Cakra & Dewi' },
      { id: 'p3', name: 'Eka & Fajar' },
      { id: 'p4', name: 'Gita & Hadi' },
    ],
    groups: { A: ['p1', 'p2', 'p3', 'p4'], B: [], C: [], D: [] },
    matches,
  }
}

function teamSnapshot(): TeamSnapshot {
  const final: TeamMatch = {
    id: 'final',
    phase: 'final',
    teamA: 't1',
    teamB: 't2',
    partai: [
      { scoreA: 30, scoreB: 20 },
      { scoreA: 21, scoreB: 30 },
      { scoreA: 30, scoreB: 25 },
    ],
    courts: ['Court 12', 'Court 12', 'Court 12'],
  }
  const group: TeamMatch = {
    id: 'g-1',
    phase: 'group',
    teamA: 't1',
    teamB: 't2',
    partai: [
      { scoreA: 30, scoreB: 25 },
      { scoreA: 30, scoreB: 28 },
      { scoreA: 20, scoreB: 30 },
    ],
    courts: ['Court 12', 'Court 12', 'Court 12'],
  }
  const roster = (prefix: string) => ({
    id: prefix,
    name: prefix,
    players: (['A+', 'A', 'B+', 'B', 'C+', 'C'] as const).map((cls) => ({
      name: `${prefix}-${cls}`,
      cls,
    })),
  })
  return {
    format: 'team',
    name: 'Team Cup',
    date: '2026-11-05',
    teams: [roster('RED'), roster('BLUE')].map((team, index) => ({
      ...team,
      id: index === 0 ? 't1' : 't2',
    })),
    matches: [group, final],
  }
}

describe('classic export rows', () => {
  it('keeps the group table order and resolves pair names', () => {
    const rows = classicGroupRows(classicSnapshot(), 'A')
    expect(rows.map((row) => row.name)).toEqual([
      'Eka & Fajar',
      'Ani & Budi',
      'Gita & Hadi',
      'Cakra & Dewi',
    ])
    expect(rows[0]).toMatchObject({ wins: 2, losses: 0, diff: 17 })
  })

  it('labels knockout rows and leaves an empty slot blank', () => {
    const rows = classicBracketRows(classicSnapshot(), 'qf')
    expect(rows).toHaveLength(2)
    expect(rows[0]).toEqual({
      label: 'QF 1',
      nameA: 'Ani & Budi',
      nameB: 'Gita & Hadi',
      scoreA: 30,
      scoreB: 22,
    })
    expect(rows[1]).toMatchObject({ nameA: '', nameB: '', scoreA: null })
  })
})

describe('team export rows', () => {
  it('counts partai wins, losses and point difference', () => {
    const rows = teamStandingRows(teamSnapshot())
    expect(rows[0]).toMatchObject({ name: 'RED', wins: 2, losses: 1, points: 2 })
    expect(rows[0].diff).toBe(80 - 83)
    expect(rows[1]).toMatchObject({ name: 'BLUE', wins: 1, losses: 2, points: 1 })
  })

  it('maps the final to the three partai, players by class', () => {
    const final = teamFinalExport(teamSnapshot())
    expect(final).not.toBeNull()
    expect(final).toMatchObject({
      teamAName: 'RED',
      teamBName: 'BLUE',
      teamAWins: 2,
      teamBWins: 1,
    })
    expect(final?.partai.map((row) => row.tier)).toEqual([
      'C+ / C',
      'A+ / A',
      'B+ / B',
    ])
    expect(final?.partai[0]).toMatchObject({
      nameA: 'RED-C+',
      nameB: 'BLUE-C',
      scoreA: 30,
      scoreB: 20,
    })
    expect(final?.partai[1]).toMatchObject({ nameA: 'RED-A+', nameB: 'BLUE-A' })
  })

  it('returns null while the final does not exist', () => {
    const snapshot = teamSnapshot()
    snapshot.matches = snapshot.matches.filter((match) => match.phase !== 'final')
    expect(teamFinalExport(snapshot)).toBeNull()
  })
})
