import { describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_TEAM_COURTS,
  buildTeamMatchFiles,
  computeTeamStandings,
  generateTeamDraw,
  teamMatchDirty,
  teamMatchOutcome,
  teamMatchPoints,
  type TeamInfo,
  type TeamMatch,
} from '../teamTournament'

const canvas = vi.hoisted(() => ({
  drawMatchPost: vi.fn(),
  drawTeamMatchPost: vi.fn(),
  loadImage: vi.fn(async () => ({ width: 10, height: 10 }) as HTMLImageElement),
  canvasToBlob: vi.fn(async () => new Blob(['jpeg'], { type: 'image/jpeg' })),
}))

vi.mock('../canvasPost', () => ({
  drawMatchPost: canvas.drawMatchPost,
  drawTeamMatchPost: canvas.drawTeamMatchPost,
  loadImage: canvas.loadImage,
  ANNIVERSARY_LABEL: 'ANNIVERSARY',
}))

vi.mock('../share', () => ({ canvasToBlob: canvas.canvasToBlob }))

const team = (id: string, name: string): TeamInfo => ({ id, name, players: [] })

const partai = (a: number | null, b: number | null) => ({ scoreA: a, scoreB: b })

const match = (
  id: string,
  teamA: string,
  teamB: string,
  partaiScores: Array<[number | null, number | null]>,
  courts: [string, string, string] = DEFAULT_TEAM_COURTS,
): TeamMatch => ({
  id,
  phase: 'group',
  teamA,
  teamB,
  partai: partaiScores.map(([a, b]) => partai(a, b)),
  courts,
})

describe('teamMatchOutcome', () => {
  it('counts partai wins per side and marks the match complete only when all three are scored', () => {
    expect(teamMatchOutcome(match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 28]]))).toEqual({
      aWins: 2,
      bWins: 1,
      complete: true,
    })

    expect(teamMatchOutcome(match('m2', 't1', 't2', [[30, 20], [25, 30], [null, null]]))).toEqual({
      aWins: 1,
      bWins: 1,
      complete: false,
    })
  })

  it('leaves the counts level when the decided partai split one each', () => {
    // There is no draw flag to read: a tie is only observable as equal counts,
    // and it can only happen while a partai is missing.
    const outcome = teamMatchOutcome(match('m3', 't1', 't2', [[30, 20], [20, 30], [null, null]]))

    expect(outcome.aWins).toBe(outcome.bWins)
    expect(outcome.complete).toBe(false)
  })
})

describe('teamMatchPoints', () => {
  it('awards 3 for a sweep, 2 for a 2-1 win, 1 for a 1-2 loss and 0 for a whitewash loss', () => {
    expect(teamMatchPoints(3, 0)).toBe(3)
    expect(teamMatchPoints(2, 1)).toBe(2)
    expect(teamMatchPoints(1, 2)).toBe(1)
    expect(teamMatchPoints(0, 3)).toBe(0)
  })
})

describe('computeTeamStandings', () => {
  it('adds partai wins and points, not matches won', () => {
    const rows = computeTeamStandings(
      [team('t1', 'Red'), team('t2', 'Blue')],
      [match('m1', 't1', 't2', [[30, 20], [30, 25], [20, 30]])],
    )

    // One match played. t1 won two partai and scored 80-75; the match result
    // is not what the row counts.
    expect(rows[0]).toMatchObject({
      teamId: 't1',
      played: 1,
      teamWins: 2,
      teamLosses: 1,
      points: 2,
      pointsFor: 80,
      pointsAgainst: 75,
    })
    expect(rows[1]).toMatchObject({
      teamId: 't2',
      played: 1,
      teamWins: 1,
      teamLosses: 2,
      points: 1,
      pointsFor: 75,
      pointsAgainst: 80,
    })
  })

  it('skips a match that still has an unscored partai', () => {
    const rows = computeTeamStandings(
      [team('t1', 'Red'), team('t2', 'Blue')],
      [match('m1', 't1', 't2', [[30, 20], [30, 25], [null, null]])],
    )

    expect(rows.every((row) => row.played === 0 && row.teamWins === 0 && row.teamLosses === 0)).toBe(
      true,
    )
  })

  it('orders by points, then partai difference, then point difference', () => {
    const rows = computeTeamStandings(
      [team('t1', 'Red'), team('t2', 'Blue'), team('t3', 'Green')],
      [
        // t1 sweeps: 3 points, partai +3.
        match('m1', 't1', 't2', [[30, 10], [30, 10], [30, 10]]),
        // t3 edges t2 late: 2 points, partai +1.
        match('m2', 't3', 't2', [[30, 20], [20, 30], [30, 28]]),
      ],
    )

    expect(rows.map((row) => [row.teamId, row.points])).toEqual([
      ['t1', 3],
      ['t3', 2],
      ['t2', 1],
    ])
  })
})

describe('generateTeamDraw', () => {
  it('never pairs a team with itself and uses every team once in each of the three rounds', () => {
    const ids = ['t1', 't2', 't3', 't4', 't5', 't6']
    const draw = generateTeamDraw(ids)

    expect(draw).toHaveLength(9)
    expect(draw.every(([a, b]) => a !== b)).toBe(true)

    for (let round = 0; round < 3; round += 1) {
      const block = draw.slice(round * 3, round * 3 + 3)
      const playing = block.flatMap(([a, b]) => [a, b])
      expect(playing.slice().sort()).toEqual(ids.slice().sort())
      expect(new Set(block.map(([, , court]) => court)).size).toBe(3)
    }

    // No pairing repeats, so every team meets three different opponents.
    const pairs = draw.map(([a, b]) => [a, b].slice().sort().join('-'))
    expect(new Set(pairs).size).toBe(9)
    expect(draw.every(([a, b]) => ids.includes(a) && ids.includes(b))).toBe(true)
  })

  it('refuses a field that is not exactly six teams', () => {
    expect(() => generateTeamDraw(['t1', 't2', 't3', 't4', 't5'])).toThrow(
      'generateTeamDraw membutuhkan tepat 6 tim',
    )
  })
})

describe('teamMatchDirty', () => {
  it('treats a match with the same scores and courts as clean', () => {
    const local = match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 28]])
    // A second object with the same content: nothing changed on the wire.
    const server = match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 28]])

    expect(local).not.toBe(server)
    expect(teamMatchDirty(local, server)).toBe(false)
  })

  it('reports a changed partai score or court, and a missing server row', () => {
    const local = match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 28]])

    expect(teamMatchDirty(local, match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 29]]))).toBe(true)
    expect(teamMatchDirty(local, match('m1', 't1', 't2', [[30, 20], [25, 30], [30, 28]], ['Court 1', 'Court 13', 'Court 14']))).toBe(true)
    expect(teamMatchDirty(local, undefined)).toBe(true)
  })
})

describe('buildTeamMatchFiles', () => {
  const roster = (prefix: string): TeamInfo['players'] =>
    (['A+', 'A', 'B+', 'B', 'C+', 'C'] as const).map((cls) => ({
      name: `${prefix}-${cls}`,
      cls,
    }))

  const teams: TeamInfo[] = [
    { id: 't1', name: 'RED RAPTORS', players: roster('red') },
    { id: 't2', name: 'NOBODY', players: roster('nobody') },
  ]

  const photo = (label: string) => ({ label }) as unknown as HTMLImageElement
  const photoKey = (partaiIdx: number) => `photo-${partaiIdx}`

  const options = (partaiScores: Array<[number | null, number | null]>) => ({
    teams,
    match: match('m1', 't1', 't2', partaiScores),
    partaiPhotos: {
      'photo-0': photo('partai-0'),
      'photo-1': photo('partai-1'),
      'photo-2': photo('partai-2'),
    } as Record<string, HTMLImageElement>,
    photoKey,
    overlays: {},
    matchSubtitle: 'GROUP A',
    summarySubtitle: 'GROUP A',
    filePrefix: 'group-a',
  })

  it('writes a post for each partai that has a photo and a score, then one summary card', async () => {
    const { files, teamAName, teamBName } = await buildTeamMatchFiles(
      options([[30, 20], [null, null], [25, 30]]),
    )

    // The middle partai has a photo but no score, so it earns no post.
    expect(canvas.drawMatchPost).toHaveBeenCalledTimes(2)
    expect(canvas.drawTeamMatchPost).toHaveBeenCalledTimes(1)
    expect(files.map((file) => file.name)).toEqual([
      'group-a-C+C.jpg',
      'group-a-B+B.jpg',
      'group-a-summary.jpg',
    ])

    const summary = canvas.drawTeamMatchPost.mock.calls[0][0]
    expect(summary.partaiRows).toEqual([
      { tier: 'C+C', nameA: 'red-C+/red-C', nameB: 'nobody-C+/nobody-C', scoreA: 30, scoreB: 20 },
      { tier: 'A+A', nameA: 'red-A+/red-A', nameB: 'nobody-A+/nobody-A', scoreA: null, scoreB: null },
      { tier: 'B+B', nameA: 'red-B+/red-B', nameB: 'nobody-B+/nobody-B', scoreA: 25, scoreB: 30 },
    ])
    expect(summary).toMatchObject({ teamAName, teamBName, teamAWins: 1, teamBWins: 1 })
    expect([teamAName, teamBName]).toEqual(['RED RAPTORS', 'NOBODY'])
  })

  it('still writes the summary card when no partai has a photo or a score', async () => {
    const empty = options([[null, null], [null, null], [null, null]])
    const { files } = await buildTeamMatchFiles({ ...empty, partaiPhotos: {} })

    expect(canvas.drawMatchPost).not.toHaveBeenCalled()
    expect(files.map((file) => file.name)).toEqual(['group-a-summary.jpg'])
  })
})
