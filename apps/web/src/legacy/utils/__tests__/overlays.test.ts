import { describe, expect, it, vi } from 'vitest'
import { loadOverlayImages } from '../overlays'

const loadImage = vi.hoisted(() => vi.fn())

vi.mock('../canvasPost', () => ({ loadImage }))

describe('loadOverlayImages', () => {
  it('skips an undefined path and leaves a missing file out without failing the rest', async () => {
    const logo = { src: '/logo.png' } as unknown as HTMLImageElement
    loadImage.mockImplementation(async (src: string) => {
      if (src === '/missing.png') throw new Error('404')
      return { src } as unknown as HTMLImageElement
    })

    const loaded = await loadOverlayImages({
      logo: '/logo.png',
      badge: '/missing.png',
      sponsor: undefined,
    })

    expect(loaded).toEqual({ logo })
    // The undefined path never reaches the loader.
    expect(loadImage.mock.calls.map(([src]) => src)).toEqual(['/logo.png', '/missing.png'])
  })
})
