import { describe, expect, it } from 'vitest'
import {
  drawBracketRoundCover,
  drawDate,
  drawGroupSummary,
  drawMatchPost,
  drawStandingsCanvas,
  drawTeamMatchPost,
  truncateToWidth,
} from '../canvasPost'
import type { PlayerStanding } from '../standings'
import type { StandingRow } from '../tournament'
import { toPlayerId } from '../../types'
import { CANVAS_COLORS as C } from '../../config/canvas'
import { fakeImage, imageLabelOf, installRecordingContext } from '@/test/recordingContext'

const W = 1080
const H = 1350

function standing(name: string, wins: number, losses: number, pointsFor: number, diff: number): PlayerStanding {
  return {
    wins,
    losses,
    pointsFor,
    pointsAgainst: 0,
    diff,
    player: { id: toPlayerId(name.toLowerCase()), name, gender: 'M', tier: 3 },
  }
}

describe('drawMatchPost name and score row', () => {
  it('records the A name left aligned at x 60, the B name right aligned at x 1020, then the centred score', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')

    drawMatchPost({
      canvas,
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: 21,
      scoreB: 18,
      subtitle: 'FINAL',
    })

    expect(canvas.width).toBe(W)
    expect(canvas.height).toBe(H)
    expect(imageLabelOf(rec.callsOf('drawImage')[0].args[0])).toBe('photo')

    const row = rec
      .fillTexts()
      .filter((t) => t.text === 'RINA / DEWI' || t.text === 'SARI / AYU')
    expect(row).toHaveLength(2)

    const [a, b] = row
    expect(a).toMatchObject({ text: 'RINA / DEWI', x: 60, y: 1160, textAlign: 'left', fillStyle: C.white })
    expect(b).toMatchObject({ text: 'SARI / AYU', x: 1020, y: 1160, textAlign: 'right', fillStyle: C.white })

    const score = rec.fillTexts().filter((t) => t.text === '21 \u2013 18')
    expect(score).toHaveLength(1)
    expect(score[0]).toMatchObject({
      x: 540,
      y: 1160,
      textAlign: 'center',
      fillStyle: C.accent,
      font: 'bold 42px monospace',
    })

    expect(a.index).toBeLessThan(b.index)
    expect(b.index).toBeLessThan(score[0].index)
  })

  it('records the "vs" placeholder instead of a score when scoreA is null', () => {
    const rec = installRecordingContext()

    drawMatchPost({
      canvas: document.createElement('canvas'),
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: null,
      scoreB: 18,
      subtitle: 'FINAL',
    })

    const scoreRow = rec.fillTexts().filter((t) => t.y === 1160 && t.textAlign === 'center')
    expect(scoreRow.map((t) => t.text)).toEqual(['\u2014 vs \u2014'])
    expect(rec.texts().some((t) => t.text === '21 \u2013 18')).toBe(false)
  })

  it('records the "vs" placeholder instead of a score when scoreB is null', () => {
    const rec = installRecordingContext()

    drawMatchPost({
      canvas: document.createElement('canvas'),
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: 21,
      scoreB: null,
      subtitle: 'FINAL',
    })

    const scoreRow = rec.fillTexts().filter((t) => t.y === 1160 && t.textAlign === 'center')
    expect(scoreRow.map((t) => t.text)).toEqual(['\u2014 vs \u2014'])
    expect(rec.texts().some((t) => t.text.includes('\u2013'))).toBe(false)
  })
})

describe('drawMatchPost header selection', () => {
  it('records the anniversary header when cardLogo is given, not the tournament label', () => {
    const rec = installRecordingContext()

    drawMatchPost({
      canvas: document.createElement('canvas'),
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: 21,
      scoreB: 18,
      subtitle: 'FINAL',
      cardLogo: fakeImage(200, 100, 'cardLogo'),
    })

    const anniversary = rec.fillTexts().filter((t) => t.text === 'MAJADU 1\u02E2\u1D57 ANNIVERSARY')
    expect(anniversary).toHaveLength(2)
    expect(anniversary[0]).toMatchObject({ textAlign: 'center', letterSpacing: '8px', fillStyle: C.white })
    expect(anniversary[0].x).toBeCloseTo(247.6, 6)
    expect(anniversary[1].x).toBeCloseTo(832.4, 6)
    expect(anniversary[0].index).toBeLessThan(anniversary[1].index)

    expect(rec.images()).toContain('cardLogo')
    expect(rec.texts().some((t) => t.text === 'MAJADU INTERNAL TOURNAMENT 2026')).toBe(false)
  })

  it('records the headerLabel twice, right aligned then left aligned, when headerLabel is given', () => {
    const rec = installRecordingContext()

    drawMatchPost({
      canvas: document.createElement('canvas'),
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: 21,
      scoreB: 18,
      subtitle: 'FINAL',
      headerLabel: 'MY CUP',
    })

    const label = rec.fillTexts().filter((t) => t.text === 'MY CUP')
    expect(label).toHaveLength(2)
    expect(label[0]).toMatchObject({ x: 430, textAlign: 'right', fillStyle: C.white })
    expect(label[1]).toMatchObject({ x: 650, textAlign: 'left', fillStyle: C.white })
    expect(label[0].index).toBeLessThan(label[1].index)

    expect(rec.texts().some((t) => t.text === 'MAJADU INTERNAL TOURNAMENT 2026')).toBe(false)
    expect(rec.texts().some((t) => t.text === 'MAJADU 1\u02E2\u1D57 ANNIVERSARY')).toBe(false)
  })

  it('records the plain tournament header when neither cardLogo nor headerLabel is given', () => {
    const rec = installRecordingContext()

    drawMatchPost({
      canvas: document.createElement('canvas'),
      photo: fakeImage(W, H, 'photo'),
      pairAName: 'RINA / DEWI',
      pairBName: 'SARI / AYU',
      scoreA: 21,
      scoreB: 18,
      subtitle: 'FINAL',
    })

    const label = rec.fillTexts().filter((t) => t.text === 'MAJADU INTERNAL TOURNAMENT 2026')
    expect(label).toHaveLength(2)
    expect(label[0]).toMatchObject({ x: 430, textAlign: 'right' })
    expect(label[1]).toMatchObject({ x: 650, textAlign: 'left' })

    expect(rec.texts().some((t) => t.text === 'MAJADU 1\u02E2\u1D57 ANNIVERSARY')).toBe(false)
  })
})

describe('truncateToWidth', () => {
  it('returns a name that already fits unchanged', () => {
    const { ctx } = installRecordingContext()
    ctx.font = '20px Arial, sans-serif'

    expect(truncateToWidth(ctx, 'ABC', 100)).toBe('ABC')
  })

  it('shortens an over-wide name and appends an ellipsis', () => {
    const { ctx } = installRecordingContext()
    ctx.font = '20px Arial, sans-serif'

    const result = truncateToWidth(ctx, 'ABCDEFGHIJ', 100)

    expect(result).toBe('ABCDEFG\u2026')
    expect(result.endsWith('\u2026')).toBe(true)
    expect(ctx.measureText(result).width).toBeLessThanOrEqual(100)
  })

  it('keeps at least one character when the width is smaller than a single glyph', () => {
    const { ctx } = installRecordingContext()
    ctx.font = '20px Arial, sans-serif'

    expect(truncateToWidth(ctx, 'ABCDEFGHIJ', 12)).toBe('A\u2026')
  })
})

describe('drawStandingsCanvas rows', () => {
  const meta = { date: '2026-07-12', title: 'SATURDAY', playerCount: 12 }

  it('records one row per player in the order handed in, with medals for the top three', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')
    canvas.width = W
    canvas.height = H

    drawStandingsCanvas({
      canvas,
      standings: [
        standing('RINA', 3, 1, 90, 12),
        standing('SARI', 2, 2, 84, 0),
        standing('TONO', 2, 1, 70, -4),
        standing('UCOK', 1, 2, 60, 2),
      ],
      meta,
      overlays: {},
      isStory: false,
    })

    expect(rec.indexOfText('2026-07-12 \u00B7 SATURDAY')).toBeGreaterThan(-1)
    expect(rec.fillTexts().find((t) => t.text === '2026-07-12 \u00B7 SATURDAY')).toMatchObject({
      x: 150,
      y: 208,
      textAlign: 'left',
      fillStyle: C.textDim,
    })
    expect(rec.fillTexts().find((t) => t.text === 'TOP 4 OF 12 PLAYERS')).toMatchObject({
      x: 150,
      y: 252,
      fillStyle: C.accent,
    })

    const names = rec.fillTexts().filter((t) => ['RINA', 'SARI', 'TONO', 'UCOK'].includes(t.text))
    expect(names.map((t) => t.text)).toEqual(['RINA', 'SARI', 'TONO', 'UCOK'])
    expect(names.map((t) => t.x)).toEqual([230, 230, 230, 230])
    expect(names[0].y).toBeCloseTo(373.68, 6)
    expect(names[1].y).toBeCloseTo(441.68, 6)
    expect(names[2].y).toBeCloseTo(509.68, 6)
    expect(names[3].y).toBeCloseTo(577.68, 6)
    expect(names.map((t) => t.fillStyle)).toEqual([C.accent, C.silver, C.warning, C.textPrimary])

    const medals = rec.fillTexts().filter((t) => ['\u{1F947}', '\u{1F948}', '\u{1F949}', '4th'].includes(t.text))
    expect(medals.map((t) => t.text)).toEqual(['\u{1F947}', '\u{1F948}', '\u{1F949}', '4th'])
    expect(medals.map((t) => t.x)).toEqual([178, 178, 178, 178])
    expect(medals[3].fillStyle).toBe(C.muted)

    const records = rec.fillTexts().filter((t) => t.x === 690 && t.y > 340)
    expect(records.map((t) => t.text)).toEqual(['3-1', '2-2', '2-1', '1-2'])
    expect(records.every((t) => t.textAlign === 'right' && t.fillStyle === C.success)).toBe(true)

    const diffs = rec.fillTexts().filter((t) => t.x === 810 && t.y > 340)
    expect(diffs.map((t) => t.text)).toEqual(['+12', '0', '-4', '+2'])
    expect(diffs.map((t) => t.fillStyle)).toEqual([C.success, C.border, C.error, C.success])

    const points = rec.fillTexts().filter((t) => t.x === 930 && t.y > 340)
    expect(points.map((t) => t.text)).toEqual(['90', '84', '70', '60'])
    expect(points.every((t) => t.textAlign === 'right' && t.fillStyle === C.white)).toBe(true)
  })

  it('records no player row when the standings list is empty', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')
    canvas.width = W
    canvas.height = H

    drawStandingsCanvas({ canvas, standings: [], meta, overlays: {}, isStory: false })

    const labels = rec.fillTexts().map((t) => t.text)
    expect(labels).toContain('TOP 0 OF 12 PLAYERS')
    expect(rec.fillTexts().some((t) => t.y > 350)).toBe(false)
    expect(labels.filter((t) => /^\d+(st|nd|rd|th)$/.test(t))).toEqual([])
    expect(labels.filter((t) => t.startsWith('\u{1F947}') || t.startsWith('\u{1F948}') || t.startsWith('\u{1F949}'))).toEqual([])
  })

  it('records only the first ten players when the standings list is longer', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')
    canvas.width = W
    canvas.height = H
    const many = Array.from({ length: 12 }, (_, i) => standing(`P${String(i + 1).padStart(2, '0')}`, 3, 1, 90, 1))

    drawStandingsCanvas({ canvas, standings: many, meta, overlays: {}, isStory: false })

    expect(rec.indexOfText('TOP 10 OF 12 PLAYERS')).toBeGreaterThan(-1)
    expect(rec.indexOfText('P10')).toBeGreaterThan(-1)
    expect(rec.indexOfText('P11')).toBe(-1)
    expect(rec.indexOfText('P12')).toBe(-1)
  })
})

describe('drawTeamMatchPost', () => {
  it('records each partai result and the team totals', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')

    drawTeamMatchPost({
      canvas,
      teamAName: 'GARUDA',
      teamBName: 'RAJAWALI',
      teamAWins: 2,
      teamBWins: 1,
      partaiRows: [
        { tier: 'MD1', nameA: 'ANDI / BUDI', nameB: 'CECEP / DEDI', scoreA: 21, scoreB: 15 },
        { tier: 'WD1', nameA: 'EKA / FITRI', nameB: 'GITA / HANA', scoreA: 14, scoreB: 21 },
        { tier: 'XD1', nameA: 'IRMA / JOKO', nameB: 'KIKI / LALA', scoreA: null, scoreB: null },
      ],
      subtitle: 'GROUP STAGE',
    })

    expect(canvas.width).toBe(W)
    expect(canvas.height).toBe(H)

    expect(rec.fillTexts().find((t) => t.text === 'GROUP STAGE')).toMatchObject({
      x: 540,
      y: 200,
      textAlign: 'center',
      fillStyle: C.textDim,
    })
    expect(rec.fillTexts().find((t) => t.text === 'MATCH RESULT')).toMatchObject({
      x: 540,
      y: 295,
      textAlign: 'center',
      fillStyle: C.accent,
      font: 'bold italic 88px Arial, sans-serif',
    })

    expect(rec.fillTexts().find((t) => t.text === '2 \u2013 1')).toMatchObject({
      x: 540,
      y: 903.5,
      textAlign: 'center',
      fillStyle: C.accent,
    })
    expect(rec.fillTexts().find((t) => t.text === 'GARUDA')).toMatchObject({
      x: 100,
      y: 991,
      textAlign: 'left',
      fillStyle: C.white,
    })
    expect(rec.fillTexts().find((t) => t.text === 'RAJAWALI')).toMatchObject({
      x: 980,
      y: 991,
      textAlign: 'right',
      fillStyle: C.textDim,
    })

    const tiers = rec.fillTexts().filter((t) => ['MD1', 'WD1', 'XD1'].includes(t.text))
    expect(tiers.map((t) => t.text)).toEqual(['MD1', 'WD1', 'XD1'])
    expect(tiers.map((t) => t.y)).toEqual([1082, 1150, 1218])
    expect(tiers.every((t) => t.x === 100 && t.textAlign === 'left' && t.fillStyle === C.accent)).toBe(true)

    const scores = rec.fillTexts().filter((t) => ['21\u201315', '14\u201321', 'vs'].includes(t.text))
    expect(scores.map((t) => t.text)).toEqual(['21\u201315', '14\u201321', 'vs'])
    expect(scores.map((t) => t.x)).toEqual([540, 540, 540])
    expect(scores.map((t) => t.y)).toEqual([1082, 1150, 1218])

    const namesA = rec.fillTexts().filter((t) => ['ANDI / BUDI', 'EKA / FITRI', 'IRMA / JOKO'].includes(t.text))
    expect(namesA.map((t) => t.x)).toEqual([190, 190, 190])
    expect(namesA.map((t) => t.fillStyle)).toEqual([C.white, C.textDim, C.textDim])

    const namesB = rec.fillTexts().filter((t) => ['CECEP / DEDI', 'GITA / HANA', 'KIKI / LALA'].includes(t.text))
    expect(namesB.map((t) => t.x)).toEqual([980, 980, 980])
    expect(namesB.map((t) => t.textAlign)).toEqual(['right', 'right', 'right'])
    expect(namesB.map((t) => t.fillStyle)).toEqual([C.textDim, C.white, C.textDim])

    const headerIndex = rec.indexOfText('MAJADU 1\u02E2\u1D57 ANNIVERSARY')
    expect(headerIndex).toBeGreaterThan(tiers[2].index)
  })
})

describe('drawDate', () => {
  it('records the day twice as a shadow and a fill, then the month outline and fill, then the year', () => {
    const rec = installRecordingContext()

    drawDate(rec.ctx, W, '12', 'JUL', '2026', fakeImage(600, 200, 'brush'))

    const days = rec.fillTexts().filter((t) => t.text === '12')
    expect(days).toHaveLength(2)
    expect(days[0].fillStyle).toBe(C.black)
    expect(days[1].fillStyle).toBe(C.brand)
    expect(days[0].font).toBe('200px Granesta, Impact, sans-serif')
    expect(days[0].x).toBeCloseTo(days[1].x + 5, 6)
    expect(days[0].y).toBeCloseTo(days[1].y + 5, 6)

    const months = rec.texts().filter((t) => t.text === 'JUL')
    expect(months.map((t) => t.op)).toEqual(['strokeText', 'fillText'])
    expect(months[0].strokeStyle).toBe(C.brand)
    expect(months[0].lineWidth).toBe(10)
    expect(months[0].lineJoin).toBe('round')
    expect(months[1].fillStyle).toBe(C.darkText)
    expect(months[1].x).toBeCloseTo(months[0].x, 6)
    expect(months[1].y).toBeCloseTo(months[0].y, 6)

    const year = rec.fillTexts().filter((t) => t.text === '2026')
    expect(year).toHaveLength(1)
    expect(year[0]).toMatchObject({
      x: 0,
      textAlign: 'center',
      fillStyle: C.darkText,
      font: '72px Edosz, Impact, sans-serif',
    })
    expect(year[0].y).toBeCloseTo(10.84, 6)

    const brush = rec.callsOf('drawImage').filter((c) => imageLabelOf(c.args[0]) === 'brush')
    expect(brush).toHaveLength(1)
    expect(brush[0].args[3]).toBeGreaterThan(0)
    expect(Number(brush[0].args[1])).toBeCloseTo(-Number(brush[0].args[3]) / 2, 6)
    expect(brush[0].index).toBeLessThan(year[0].index)

    expect(days[1].index).toBeLessThan(months[0].index)
    expect(months[1].index).toBeLessThan(year[0].index)
  })

  it('fills a brand rectangle when no brush stroke image is given', () => {
    const rec = installRecordingContext()

    drawDate(rec.ctx, W, '12', 'JUL', '2026')

    const backdrop = rec.callsOf('fillRect').filter((c) => c.state.fillStyle === C.brand)
    expect(backdrop).toHaveLength(1)
    expect(Number(backdrop[0].args[2])).toBeGreaterThan(0)
    expect(Number(backdrop[0].args[0])).toBeCloseTo(-Number(backdrop[0].args[2]) / 2, 6)
    expect(rec.images()).not.toContain('brush')
  })
})

describe('drawBracketRoundCover', () => {
  it('records the round title, then each match row with its score or the vs placeholder', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')

    drawBracketRoundCover({
      canvas,
      roundTitle: 'SEMI FINAL',
      matchRows: [
        { label: 'SF1', nameA: 'RINA / DEWI', nameB: 'SARI / AYU', scoreA: 21, scoreB: 15 },
        { label: 'SF2', nameA: 'TONO / UCOK', nameB: 'EKA / FITRI', scoreA: null, scoreB: null },
      ],
    })

    expect(canvas.width).toBe(W)
    expect(canvas.height).toBe(H)
    expect(rec.callsOf('fillRect')[0]).toMatchObject({ args: [0, 0, W, H] })
    expect(rec.callsOf('fillRect')[0].state.fillStyle).toBe(C.bgDark)

    expect(rec.fillTexts().find((t) => t.text === 'SEMI FINAL')).toMatchObject({
      x: 540,
      y: 619,
      textAlign: 'center',
      fillStyle: C.accent,
    })

    const labels = rec.fillTexts().filter((t) => t.text === 'SF1' || t.text === 'SF2')
    expect(labels.map((t) => t.text)).toEqual(['SF1', 'SF2'])
    expect(labels.map((t) => t.x)).toEqual([110, 110])
    expect(labels.map((t) => t.y)).toEqual([707, 849])

    expect(rec.fillTexts().find((t) => t.text === 'RINA / DEWI')).toMatchObject({
      x: 442,
      y: 759.6,
      textAlign: 'right',
      fillStyle: C.textPrimary,
    })
    expect(rec.fillTexts().find((t) => t.text === 'SARI / AYU')).toMatchObject({
      x: 638,
      y: 759.6,
      textAlign: 'left',
    })
    expect(rec.fillTexts().filter((t) => t.text === '21\u201315').map((t) => t.x)).toEqual([540])
    expect(rec.fillTexts().filter((t) => t.text === 'vs').map((t) => t.y)).toEqual([901.6])
  })
})

describe('drawGroupSummary', () => {
  it('records the group title, the table header and one row per pair with +/-, 0 as a dash', () => {
    const rec = installRecordingContext()
    const canvas = document.createElement('canvas')
    const standings: StandingRow[] = [
      { pairId: 'p1', wins: 3, losses: 1, pointsFor: 90, pointsAgainst: 70, diff: 3 },
      { pairId: 'p2', wins: 2, losses: 2, pointsFor: 80, pointsAgainst: 80, diff: 0 },
      { pairId: 'p3', wins: 1, losses: 3, pointsFor: 60, pointsAgainst: 90, diff: -2 },
    ]
    const names: Record<string, string> = { p1: 'RINA / DEWI', p2: 'SARI / AYU', p3: 'TONO / UCOK' }

    drawGroupSummary({
      canvas,
      groupId: 'A',
      standings,
      getPairName: (id) => names[id ?? ''] ?? 'UNKNOWN',
    })

    expect(canvas.width).toBe(W)
    expect(canvas.height).toBe(H)
    expect(rec.fillTexts().find((t) => t.text === 'FINAL STANDINGS')).toMatchObject({ x: 140, y: 556 })
    expect(rec.fillTexts().find((t) => t.text === 'GROUP A')).toMatchObject({
      x: 140,
      y: 640,
      fillStyle: C.accent,
    })

    const headers = rec.fillTexts().filter((t) => ['W', 'L', '+/-'].includes(t.text))
    expect(headers.map((t) => t.text)).toEqual(['W', 'L', '+/-'])
    expect(headers.every((t) => t.y === 680)).toBe(true)

    const rows = rec.fillTexts().filter((t) => Object.values(names).includes(t.text))
    expect(rows.map((t) => t.text)).toEqual(['RINA / DEWI', 'SARI / AYU', 'TONO / UCOK'])
    expect(rows.map((t) => t.y)).toEqual([771.5, 891.5, 1011.5])

    const diffs = rec.fillTexts().filter((t) => ['+3', '\u2014', '-2'].includes(t.text))
    expect(diffs.map((t) => t.text)).toEqual(['+3', '\u2014', '-2'])
    expect(diffs.every((t) => t.textAlign === 'right')).toBe(true)
  })
})