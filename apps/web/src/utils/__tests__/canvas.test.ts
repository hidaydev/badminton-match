// Layout maths only: jsdom has no canvas, so nothing here may draw.
//
// The measure stub is deterministic (half the font size per character) which is
// enough for every centring, truncation and bounds assertion below.

import { describe, expect, it } from 'vitest'
import {
  bracketCoverLayout,
  dateOverlayLayout,
  drawDate,
  drawStandings,
  exportDimensions,
  FONT_EDOSZ,
  FONT_ROAD_RAGE,
  groupSummaryLayout,
  insideCanvas,
  matchPostLayout,
  resolveCanvas,
  ROAD_RAGE_SKEW_DEG,
  standingsLayout,
  teamMatchLayout,
} from '../canvas'
import type { CommunityConfig } from '../../community/api'
import type { StandingsRow, TeamMatchInput, TextMeasure } from '../canvas'

const measure: TextMeasure = (text, font) => {
  const size = /(\d+(?:\.\d+)?)px/.exec(font)
  return text.length * (size === null ? 0 : Number(size[1])) * 0.5
}

const DIMENSIONS = {
  'export.post_width': 1080,
  'export.post_height': 1350,
  'export.story_width': 1080,
  'export.story_height': 1920,
} as const

function config(overrides: Partial<Record<string, unknown>> = {}): CommunityConfig {
  const values: Record<string, unknown> = { ...DIMENSIONS, ...overrides }
  const result: CommunityConfig = {}
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined) continue
    result[key] = { value, source: 'platform' }
  }
  return result
}

const META = { date: '2026-11-04', title: 'Wednesday Session', playerCount: 20 }

function board(count: number): StandingsRow[] {
  return Array.from({ length: count }, (_, index) => ({
    name: `Player ${index + 1}`,
    wins: count - index,
    losses: index,
    diff: count - index * 2,
    points: 100 - index,
  }))
}

const skewed = Math.tan((ROAD_RAGE_SKEW_DEG * Math.PI) / 180)

const dimensions = exportDimensions(config())

type PaintedText = { text: string; x: number; y: number; font: string; color: string }

/**
 * Records `fillText` calls without a canvas. There is no 2d context in jsdom,
 * so this stubs the API surface and never renders anything: it only proves the
 * drawing code reads its numbers from the layout.
 */
function recordingContext(): {
  ctx: CanvasRenderingContext2D
  texts: PaintedText[]
} {
  const target: Record<string, unknown> = { font: '10px sans-serif' }
  const texts: PaintedText[] = []
  const gradient = { addColorStop: () => undefined }
  const ctx = new Proxy(target, {
    get(state, property) {
      if (typeof property !== 'string') return undefined
      if (property === 'measureText') return () => ({ width: 0 })
      if (property === 'createLinearGradient' || property === 'createRadialGradient') {
        return () => gradient
      }
      if (property === 'fillText') {
        return (text: string, x: number, y: number) => {
          texts.push({
            text,
            x,
            y,
            font: String(state.font),
            color: String(state.fillStyle),
          })
        }
      }
      if (property in state) return state[property]
      return () => undefined
    },
    set(state, property, value) {
      state[String(property)] = value
      return true
    },
  })
  return { ctx: ctx as unknown as CanvasRenderingContext2D, texts }
}

describe('exportDimensions', () => {
  it('reads the four platform keys', () => {
    expect(dimensions.post).toEqual({ width: 1080, height: 1350 })
    expect(dimensions.story).toEqual({ width: 1080, height: 1920 })
  })

  it('maps each key, not a shared default', () => {
    const changed = exportDimensions(
      config({
        'export.post_width': 900,
        'export.post_height': 1200,
        'export.story_width': 800,
        'export.story_height': 1600,
      }),
    )
    expect(changed.post).toEqual({ width: 900, height: 1200 })
    expect(changed.story).toEqual({ width: 800, height: 1600 })
  })

  it('fails loudly for a missing key', () => {
    const broken = config()
    delete broken['export.story_height']
    expect(() => exportDimensions(broken)).toThrow(/export\.story_height.*missing/)
  })

  it('fails for a string value', () => {
    expect(() => exportDimensions(config({ 'export.post_width': '1080' }))).toThrow(
      /export\.post_width.*integer/,
    )
  })

  it('fails for zero', () => {
    expect(() => exportDimensions(config({ 'export.post_height': 0 }))).toThrow(
      /export\.post_height.*between 320 and 4096/,
    )
  })

  it('fails above the registry bound', () => {
    expect(() => exportDimensions(config({ 'export.story_width': 5000 }))).toThrow(
      /export\.story_width.*between 320 and 4096/,
    )
  })

  it('fails for a fractional value', () => {
    expect(() => exportDimensions(config({ 'export.story_height': 1920.5 }))).toThrow(
      /export\.story_height.*integer/,
    )
  })
})

describe('standings layout', () => {
  const base = { dimensions, meta: META, rows: board(8), measure }

  it('uses the configured canvas for each variant', () => {
    expect(resolveCanvas(dimensions, 'post')).toEqual({ width: 1080, height: 1350 })
    expect(resolveCanvas(dimensions, 'story')).toEqual({ width: 1080, height: 1920 })

    const post = standingsLayout({ ...base, variant: 'post' })
    const story = standingsLayout({ ...base, variant: 'story' })

    expect(post.canvas).toEqual(dimensions.post)
    expect(story.canvas).toEqual(dimensions.story)
    expect(story.card.y).not.toBeCloseTo(post.card.y)
    expect(post.header).not.toBeNull()
    expect(story.header).toBeNull()
    // The story centres its card on the canvas.
    expect(story.card.y + story.card.height / 2).toBeCloseTo(story.canvas.height / 2)
    expect(insideCanvas(story.card, dimensions.story)).toBe(true)
  })

  it('moves with the configured width', () => {
    const wide = standingsLayout({ ...base, variant: 'post' })
    const narrowSize = exportDimensions(config({ 'export.post_width': 900 }))
    const narrow = standingsLayout({
      ...base,
      dimensions: narrowSize,
      variant: 'post',
    })

    expect(narrowSize.post.width).toBe(900)
    expect(narrow.canvas.width).toBe(900)
    expect(narrow.card.width).toBeLessThan(wide.card.width)
    expect(narrow.card.x).toBeCloseTo((90 * 900) / 1080)
    expect(narrow.rows[0].name.x).not.toBeCloseTo(wide.rows[0].name.x)
  })

  it('is deterministic', () => {
    expect(standingsLayout({ ...base, variant: 'post' })).toEqual(
      standingsLayout({ ...base, variant: 'post' }),
    )
  })

  it('paginates a 20-row board instead of overflowing the post', () => {
    const rows = board(20)
    const first = standingsLayout({ dimensions, variant: 'post', meta: META, rows, measure })
    expect(first.total).toBe(20)
    expect(first.rowsPerPage).toBeLessThan(20)
    expect(first.pageCount).toBe(2)
    expect(first.rows).toHaveLength(first.rowsPerPage)
    expect(insideCanvas(first.card, dimensions.post)).toBe(true)
    for (const row of first.rows) {
      expect(insideCanvas(row.card, dimensions.post)).toBe(true)
    }

    const second = standingsLayout({
      dimensions,
      variant: 'post',
      meta: META,
      rows,
      page: 1,
      measure,
    })
    expect(second.page).toBe(1)
    expect(second.rows).toHaveLength(20 - first.rowsPerPage)
    expect(second.rows[0].index).toBe(first.rowsPerPage)
    expect(insideCanvas(second.card, dimensions.post)).toBe(true)

    const overflow = standingsLayout({
      dimensions,
      variant: 'post',
      meta: META,
      rows,
      page: 9,
      measure,
    })
    expect(overflow.page).toBe(overflow.pageCount - 1)
  })
})

describe('date overlay', () => {
  const date = { day: '04', month: 'NOV', year: '2026', measure }

  it('skews the day and the month in Road Rage, year in Edosz', () => {
    const layout = dateOverlayLayout({ dimensions, variant: 'post', ...date })
    expect(layout.day.fill.font).toContain('Road Rage')
    expect(layout.month.text.font).toContain('Road Rage')
    expect(layout.yearPlate.year.font).toContain('Edosz')
    expect(FONT_ROAD_RAGE).toContain('Road Rage')
    expect(FONT_EDOSZ).toContain('Edosz')
    expect(layout.day.fill.skewX).toBeCloseTo(skewed)
    expect(layout.day.shadow.skewX).toBeCloseTo(skewed)
    expect(layout.month.text.skewX).toBeCloseTo(skewed)
    // The month still leans the other way on top of the skew.
    expect(layout.month.text.rotation).toBeCloseTo((-5 * Math.PI) / 180)
  })

  it('keeps the year plate inside both canvases', () => {
    const post = dateOverlayLayout({ dimensions, variant: 'post', ...date })
    const story = dateOverlayLayout({ dimensions, variant: 'story', ...date })
    expect(post.canvas).toEqual(dimensions.post)
    expect(story.canvas).toEqual(dimensions.story)
    expect(insideCanvas(post.yearPlate.bounds, dimensions.post)).toBe(true)
    expect(insideCanvas(story.yearPlate.bounds, dimensions.story)).toBe(true)
    expect(insideCanvas(post.bounds, dimensions.post)).toBe(true)
    expect(insideCanvas(story.bounds, dimensions.story)).toBe(true)
    // The plate is rotated, so its bounds are wider than its box.
    expect(post.yearPlate.bounds.width).toBeGreaterThan(post.yearPlate.rect.width)
  })

  it('is deterministic', () => {
    expect(dateOverlayLayout({ dimensions, variant: 'post', ...date })).toEqual(
      dateOverlayLayout({ dimensions, variant: 'post', ...date }),
    )
  })
})

describe('match post layout', () => {
  const base = {
    pairAName: 'Fredy / Sachiel',
    pairBName: 'Rizky / Bagas',
    scoreA: 30,
    scoreB: 24,
    subtitle: 'WEEKLY SESSION',
    measure,
  }

  it('anchors the footer to the configured height', () => {
    const post = matchPostLayout({ ...base, dimensions, variant: 'post' })
    const story = matchPostLayout({ ...base, dimensions, variant: 'story' })

    expect(post.footer.rect.y).toBeCloseTo(1350 - 270)
    expect(story.footer.rect.y).toBeCloseTo(1920 - 270)
    expect(post.footer.rect.y).not.toBeCloseTo(story.footer.rect.y)
    // The score row rides the footer, so it moves with the configured height.
    expect(story.score.y).toBeGreaterThan(post.score.y)
    expect(post.score.y).toBeLessThan(post.subtitle.y)
    expect(story.score.y).toBeLessThan(story.subtitle.y)
    expect(post.score.text).toBe('30 \u2013 24')
  })

  it('mirrors the chevron from the layout box', () => {
    const layout = matchPostLayout({
      ...base,
      dimensions,
      variant: 'post',
      aspects: { chevrons: 1.5 },
    })
    const mirrored = layout.chevrons
    expect(mirrored).not.toBeNull()
    expect(mirrored?.mirrored.rotation).toBeCloseTo(Math.PI)
    expect(mirrored?.mirrored.pivot.x).toBeCloseTo(
      (mirrored?.mirrored.rect.x ?? 0) + (mirrored?.mirrored.rect.width ?? 0) / 2,
    )
    expect(insideCanvas(layout.footer.rect, dimensions.post)).toBe(true)
  })
})

describe('draw follows the layout', () => {
  it('paints the date overlay where the layout puts it', () => {
    const layout = dateOverlayLayout({
      dimensions,
      variant: 'post',
      day: '04',
      month: 'NOV',
      year: '2026',
      measure,
    })
    const { ctx, texts } = recordingContext()
    drawDate(ctx, layout)

    const day = texts.filter((entry) => entry.text === '04')
    expect(day).toHaveLength(2)
    expect(day.every((entry) => entry.font.includes('Road Rage'))).toBe(true)
    expect(day[1].x).toBe(layout.day.fill.x)
    expect(day[1].y).toBe(layout.day.fill.y)
    expect(day[1].color).toBe('#F5B400')
    expect(day[0].color).toBe('#000000')

    const year = texts.find((entry) => entry.text === '2026')
    expect(year?.font).toContain('Edosz')
    expect(year?.x).toBe(layout.yearPlate.year.x)
    expect(year?.y).toBe(layout.yearPlate.year.y)

    expect(texts.some((entry) => entry.text === 'NOV')).toBe(true)
  })

  it('paints the standings rows the layout describes', () => {
    const layout = standingsLayout({
      dimensions,
      variant: 'post',
      meta: META,
      rows: board(3),
      measure,
    })
    const { ctx, texts } = recordingContext()
    expect(() => drawStandings(ctx, layout)).not.toThrow()

    expect(texts.some((entry) => entry.text === 'TOP 3 OF 20 PLAYERS')).toBe(true)
    expect(texts.some((entry) => entry.text === '2026-11-04 \u00b7 Wednesday Session')).toBe(true)
    for (const row of layout.rows) {
      const painted = texts.find((entry) => entry.text === row.name.text)
      expect(painted?.x).toBe(row.name.x)
      expect(painted?.y).toBe(row.name.y)
    }
  })
})

describe('bracket and team layouts', () => {
  it('grows the bracket card with the story height', () => {
    const rows = [
      { label: 'QF 1', nameA: 'A / B', nameB: 'C / D', scoreA: 30, scoreB: 12 },
      { label: 'QF 2', nameA: 'E / F', nameB: 'G / H', scoreA: null, scoreB: null },
    ]
    const post = bracketCoverLayout({
      dimensions,
      variant: 'post',
      roundTitle: 'QUARTER FINAL',
      rows,
      measure,
    })
    const story = bracketCoverLayout({
      dimensions,
      variant: 'story',
      roundTitle: 'QUARTER FINAL',
      rows,
      measure,
    })
    expect(post.rows).toHaveLength(2)
    expect(post.rows[1].score.text).toBe('vs')
    expect(story.card.height).toBeGreaterThan(post.card.height)
    expect(story.card.y).not.toBeCloseTo(post.card.y)
    expect(insideCanvas(post.card, dimensions.post)).toBe(true)
  })

  it('marks the top two group pairs as advancing', () => {
    const layout = groupSummaryLayout({
      dimensions,
      variant: 'post',
      groupId: 'A',
      rows: [
        { name: 'Fredy / Sachiel', wins: 3, losses: 0, diff: 18 },
        { name: 'Rizky / Bagas', wins: 2, losses: 1, diff: 6 },
        { name: 'Andi / Budi', wins: 1, losses: 2, diff: -6 },
        { name: 'Cahya / Dedi', wins: 0, losses: 3, diff: -18 },
      ],
      measure,
    })
    expect(layout.rows.map((row) => row.advancing)).toEqual([true, true, false, false])
    expect(layout.rows[0].diff.text).toBe('+18')
    expect(layout.rows[3].diff.text).toBe('-18')
    expect(layout.rows[2].dot).toBeNull()
    expect(layout.rows[2].diff.text).toBe('-6')
    expect(layout.title.text).toBe('GROUP A')
    expect(insideCanvas(layout.card, dimensions.post)).toBe(true)
  })

  it('places the team photos on their own half', () => {
    const input: Omit<TeamMatchInput, 'variant'> = {
      dimensions,
      teamAName: 'RED RAPTORS',
      teamBName: 'BLUE WAVES',
      teamAWins: 3,
      teamBWins: 0,
      partai: [
        { tier: 'C+/C', nameA: 'A / B', nameB: 'C / D', scoreA: 30, scoreB: 21 },
        { tier: 'A+/A', nameA: 'E / F', nameB: 'G / H', scoreA: null, scoreB: null },
      ],
      subtitle: 'GROUP STAGE',
      aspects: { teamAPhoto: 0.6, teamBPhoto: 0.6 },
      measure,
    }
    const layout = teamMatchLayout({ ...input, variant: 'post' })
    expect(layout.photos).toHaveLength(2)
    // The losing side is drawn first, in greyscale.
    expect(layout.photos[0].side).toBe('right')
    expect(layout.photos[0].grayscale).toBe(true)
    expect(layout.photos[1].grayscale).toBe(false)
    expect(layout.partai[1].score.text).toBe('vs')
    expect(layout.score.text).toBe('3 \u2013 0')
    expect(layout.partai[0].band.y).toBeLessThan(layout.partai[1].band.y)
    expect(insideCanvas(layout.panel.rect, dimensions.post)).toBe(true)
  })
})
