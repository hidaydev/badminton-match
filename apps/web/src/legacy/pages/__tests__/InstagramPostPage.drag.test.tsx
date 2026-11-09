import { fireEvent, render, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import InstagramPostPage from '../InstagramPostPage'

const mocks = vi.hoisted(() => ({
  loadImage: vi.fn(async () => ({ width: 100, height: 100 })),
  drawPostCanvas: vi.fn(),
  loadOverlayImages: vi.fn(async () => ({})),
}))

vi.mock('../../queries', () => ({
  useListSessions: () => ({ data: [] }),
  useFetchSession: () => vi.fn(),
}))

vi.mock('../../utils/canvasPost', () => ({
  loadImage: mocks.loadImage,
  drawStandingsCanvas: vi.fn(),
}))

vi.mock('../../utils/canvas-templates', () => ({
  drawPostCanvas: mocks.drawPostCanvas,
}))

vi.mock('../../utils/overlays', () => ({
  loadOverlayImages: mocks.loadOverlayImages,
}))

describe('InstagramPostPage photo drag', () => {
  const frames: FrameRequestCallback[] = []

  beforeEach(() => {
    frames.length = 0
    mocks.drawPostCanvas.mockClear()
    vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback)
      return frames.length
    })
    vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => undefined)
    Object.defineProperty(document, 'fonts', {
      configurable: true,
      value: { ready: Promise.resolve() },
    })
    URL.createObjectURL = vi.fn(() => 'blob:photo')
    URL.revokeObjectURL = vi.fn()
  })

  it('does not dereference a cleared drag after the pointer lifts', async () => {
    const { container } = render(<InstagramPostPage />)
    const canvas = container.querySelector('canvas')
    const input = container.querySelector('input[type="file"]')
    if (canvas === null || !(input instanceof HTMLInputElement)) throw new Error('page did not mount')

    fireEvent.change(input, { target: { files: [new File(['x'], 'photo.png', { type: 'image/png' })] } })
    await waitFor(() => expect(canvas.className).toContain('cursor-grab'))

    // A release between the move and its animation frame is the race the
    // non-null assertion used to crash on.
    fireEvent.mouseDown(canvas, { clientX: 10, clientY: 10 })
    fireEvent.mouseMove(canvas, { clientX: 40, clientY: 40 })
    fireEvent.mouseUp(canvas)

    expect(() => {
      for (const frame of frames) frame(0)
    }).not.toThrow()

    const callsAfterRelease = mocks.drawPostCanvas.mock.calls.length
    for (const frame of frames) frame(0)
    expect(mocks.drawPostCanvas.mock.calls.length).toBe(callsAfterRelease)
    const lastProps = mocks.drawPostCanvas.mock.calls.at(-1)?.[0] as { photoOffset?: unknown } | undefined
    expect(lastProps?.photoOffset).toEqual({ x: 0, y: 0 })
  })
})
