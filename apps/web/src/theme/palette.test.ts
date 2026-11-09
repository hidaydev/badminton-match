import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { PALETTE } from './palette'

const css = readFileSync('src/index.css', 'utf8')

function token(name: string): string {
  const match = new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})`).exec(css)
  if (match === null) throw new Error(`--color-${name} is missing from index.css`)
  return match[1].toLowerCase()
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

  it('keeps the palette module in step with the CSS tokens', () => {
    expect(token('accent')).toBe(PALETTE.accent)
    expect(token('accent-alt')).toBe(PALETTE.accentAlt)
    expect(token('warning')).toBe(PALETTE.warning)
    expect(token('success')).toBe(PALETTE.success)
    expect(token('error')).toBe(PALETTE.error)
    expect(token('info')).toBe(PALETTE.info)
  })
})
