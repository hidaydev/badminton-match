import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { PALETTE } from './palette'

// The semantic tokens live in the shared file both apps import; this test only
// needs their declarations, wherever they are authored.
const css = [
  readFileSync('src/index.css', 'utf8'),
  readFileSync('../../packages/design-tokens/tokens.css', 'utf8'),
].join('\n')

function token(name: string): string {
  const match = new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})`).exec(css)
  if (match === null) throw new Error(`--color-${name} is missing from index.css`)
  return match[1].toLowerCase()
}

function luminance(hex: string): number {
  const channels = [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16) / 255)
  const linear = channels.map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
}

function contrast(foreground: string, background: string): number {
  const a = luminance(foreground)
  const b = luminance(background)
  const [high, low] = a > b ? [a, b] : [b, a]
  return (high + 0.05) / (low + 0.05)
}

describe('semantic status tokens', () => {
  it('gives every status role a distinct colour', () => {
    const roles = ['accent', 'accent-alt', 'warning', 'success', 'error', 'info']
    const values = roles.map(token)
    // Four roles used to resolve to the same gold, so status colour carried no
    // meaning. One hex per role is the contract.
    expect(new Set(values).size).toBe(6)
    expect(new Set([PALETTE.accent, PALETTE.accentAlt, PALETTE.warning, PALETTE.success, PALETTE.error, PALETTE.info]).size).toBe(6)
  })

  it('keeps the danger label readable on every surface, including hover', () => {
    const error = token('error')
    for (const surface of ['ground', 'surface', 'elevated']) {
      expect(contrast(error, token(surface))).toBeGreaterThanOrEqual(4.5)
    }
  })

  it('keeps the palette module in step with the CSS tokens', () => {
    expect(token('accent')).toBe(PALETTE.accent)
    expect(token('accent-alt')).toBe(PALETTE.accentAlt)
    expect(token('warning')).toBe(PALETTE.warning)
    expect(token('success')).toBe(PALETTE.success)
    expect(token('error')).toBe(PALETTE.error)
    expect(token('info')).toBe(PALETTE.info)
  })
})
