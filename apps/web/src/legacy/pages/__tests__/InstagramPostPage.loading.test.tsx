import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import InstagramPostPage from '../InstagramPostPage'
import { t } from '../../../i18n'

const mocks = vi.hoisted(() => ({
  loadOverlayImages: vi.fn(),
}))

vi.mock('../../queries', () => ({
  useListSessions: () => ({ data: [] }),
  useFetchSession: () => vi.fn(),
}))

vi.mock('../../utils/canvasPost', () => ({
  loadImage: vi.fn(async () => ({ width: 100, height: 100 })),
  drawStandingsCanvas: vi.fn(),
}))

vi.mock('../../utils/canvas-templates', () => ({
  drawPostCanvas: vi.fn(),
}))

vi.mock('../../utils/overlays', () => ({
  loadOverlayImages: mocks.loadOverlayImages,
}))

describe('InstagramPostPage overlay loading', () => {
  beforeEach(() => {
    Object.defineProperty(document, 'fonts', {
      configurable: true,
      value: { ready: Promise.resolve() },
    })
  })

  it('shows a loading state until the template overlays are in', async () => {
    let resolveOverlays: (value: unknown) => void = () => undefined
    mocks.loadOverlayImages.mockReturnValue(
      new Promise((resolve) => {
        resolveOverlays = resolve
      }),
    )

    const { container } = render(<InstagramPostPage />)
    const canvas = container.querySelector('canvas')
    if (canvas === null) throw new Error('page did not mount')

    expect(screen.getByRole('status')).toHaveTextContent(t('app.loading'))
    expect(canvas.className).toContain('invisible')

    await act(async () => {
      resolveOverlays({})
    })

    expect(screen.queryByRole('status')).toBeNull()
    expect(canvas.className).not.toContain('invisible')
  })

  it('still draws the poster when an overlay fails to load', async () => {
    mocks.loadOverlayImages.mockRejectedValue(new Error('404'))

    const { container } = render(<InstagramPostPage />)
    const canvas = container.querySelector('canvas')
    if (canvas === null) throw new Error('page did not mount')

    await act(async () => undefined)

    expect(screen.queryByRole('status')).toBeNull()
    expect(canvas.className).not.toContain('invisible')
  })
})
