// Text measurement and text blocks.
//
// Layouts measure their own text so they can centre, right-align and truncate
// without a canvas. The measure function is injected: `canvasMeasureText` is
// the browser default, `contextTextMeasure` binds a context the caller already
// has, and tests pass a deterministic stub.

import type { Point, Rect, Transform } from './geometry'
import { box, boxCenter, transformedBounds } from './geometry'
import { FONT_EDOSZ, FONT_MONO, FONT_ROAD_RAGE, FONT_SANS } from './palette'

/** `(text, font) => width`, the only thing a layout needs from a canvas. */
export type TextMeasure = (text: string, font: string) => number

export type TextAlign = 'left' | 'center' | 'right'

/** Fraction of the font size above the baseline; the rest is descent. */
const ASCENT = 0.78
const DESCENT = 0.22

export function sansFont(
  size: number,
  weight: 'normal' | 'bold' = 'normal',
  italic = false,
): string {
  const parts = [weight === 'bold' ? 'bold' : '', italic ? 'italic' : '']
  return [...parts.filter((part) => part !== ''), `${size}px ${FONT_SANS}`].join(' ')
}

export function monoFont(size: number, weight: 'normal' | 'bold' = 'normal'): string {
  const prefix = weight === 'bold' ? 'bold ' : ''
  return `${prefix}${size}px ${FONT_MONO}`
}

export function roadRageFont(size: number): string {
  return `${size}px ${FONT_ROAD_RAGE}`
}

export function edoszFont(size: number): string {
  return `${size}px ${FONT_EDOSZ}`
}

export type TextBlock = {
  text: string
  font: string
  /** Font size in canvas units, repeated so tests never parse `font`. */
  size: number
  color: string
  align: TextAlign
  /** fillText x: left edge, centre or right edge per `align`. */
  x: number
  /** fillText baseline. */
  y: number
  /** Pixels added between characters (v1 `ctx.letterSpacing`). */
  letterSpacing: number
  /** Space the text may occupy; the layout has already truncated it. */
  maxWidth: number | null
  rotation: number
  skewX: number
  pivot: Point
  /** Box the glyphs occupy, transform included. */
  bounds: Rect
}

export type TextSpec = {
  text: string
  font: string
  size: number
  color: string
  x: number
  y: number
  measure: TextMeasure
  align?: TextAlign
  letterSpacing?: number
  maxWidth?: number
  rotation?: number
  skewX?: number
  pivot?: Point
}

/** Build a positioned text block. Truncates when `maxWidth` is too small. */
export function textBlock(spec: TextSpec): TextBlock {
  const align = spec.align ?? 'left'
  const maxWidth = spec.maxWidth ?? null
  const text = truncated(spec.text, spec.font, maxWidth, spec.measure)
  const width = spec.measure(text, spec.font)
  const left =
    align === 'left' ? spec.x : align === 'right' ? spec.x - width : spec.x - width / 2
  const glyphs = box(
    left,
    spec.y - spec.size * ASCENT,
    width,
    spec.size * (ASCENT + DESCENT),
  )
  const transform: Transform = {
    rotation: spec.rotation ?? 0,
    skewX: spec.skewX ?? 0,
    pivot: spec.pivot ?? boxCenter(glyphs),
  }
  return {
    text,
    font: spec.font,
    size: spec.size,
    color: spec.color,
    align,
    x: spec.x,
    y: spec.y,
    letterSpacing: spec.letterSpacing ?? 0,
    maxWidth,
    rotation: transform.rotation ?? 0,
    skewX: transform.skewX ?? 0,
    pivot: transform.pivot ?? boxCenter(glyphs),
    bounds: transformedBounds(glyphs, transform),
  }
}

function truncated(
  text: string,
  font: string,
  maxWidth: number | null,
  measure: TextMeasure,
): string {
  if (maxWidth === null || measure(text, font) <= maxWidth) return text
  return truncateToWidth(text, maxWidth, font, measure)
}

/** v1 `truncateToWidth`: cut until the ellipsis fits. */
export function truncateToWidth(
  text: string,
  maxWidth: number,
  font: string,
  measure: TextMeasure,
): string {
  let end = text.length - 1
  while (end > 1 && measure(`${text.slice(0, end)}\u2026`, font) > maxWidth) end -= 1
  return `${text.slice(0, end)}\u2026`
}

/** v1 `ordinal`: 1st, 2nd, 3rd, 4th, 11th. */
export function ordinal(value: number): string {
  const suffixes = ['th', 'st', 'nd', 'rd']
  const rest = value % 100
  return value + (suffixes[(rest - 20) % 10] ?? suffixes[rest] ?? suffixes[0])
}

let scratch: CanvasRenderingContext2D | null | undefined

/**
 * Default measure for a real page: a detached 2d context. Layouts only fall
 * back to this when the caller injects nothing, which keeps every layout
 * function usable on its own while tests stay canvas-free.
 */
export const canvasMeasureText: TextMeasure = (text, font) => {
  if (scratch === undefined) {
    const canvas =
      typeof document === 'undefined' ? null : document.createElement('canvas')
    scratch = canvas === null ? null : canvas.getContext('2d')
  }
  if (scratch === null) {
    throw new Error('canvas text measurement is unavailable; pass a measure function')
  }
  const previous = scratch.font
  scratch.font = font
  const width = scratch.measureText(text).width
  scratch.font = previous
  return width
}

/** Measure through a context the caller already owns (used by every draw). */
export function contextTextMeasure(ctx: CanvasRenderingContext2D): TextMeasure {
  return (text, font) => {
    const previous = ctx.font
    ctx.font = font
    const width = ctx.measureText(text).width
    ctx.font = previous
    return width
  }
}
