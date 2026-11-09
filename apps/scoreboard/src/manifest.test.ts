import { describe, expect, it } from 'vitest'
import { manifest } from './manifest'

describe('web app manifest', () => {
  it('has a stable identity and install metadata', () => {
    expect(manifest.id).toBe('/')
    expect(manifest.start_url).toBe('/')
    expect(manifest.scope).toBe('/')
    expect(manifest.display).toBe('standalone')
    expect(manifest.lang).toBe('en')
    expect(manifest.categories).toEqual(['sports', 'utilities'])
  })

  it('declares any, maskable and apple-sized icons', () => {
    const purposes = manifest.icons.map(icon => ('purpose' in icon ? icon.purpose : 'any'))
    expect(purposes).toContain('maskable')
    expect(manifest.icons.map(icon => icon.sizes)).toEqual(
      expect.arrayContaining(['192x192', '512x512']),
    )
  })

  it('carries one wide and one narrow screenshot', () => {
    expect(manifest.screenshots.map(shot => shot.form_factor)).toEqual(['narrow', 'wide'])
    for (const shot of manifest.screenshots) {
      expect(shot.type).toBe('image/png')
      expect(shot.sizes).toMatch(/^\d+x\d+$/)
    }
  })

  it('offers a shortcut back into the board', () => {
    expect(manifest.shortcuts.length).toBeGreaterThan(0)
    expect(manifest.shortcuts[0].url).toBe('/')
  })
})
