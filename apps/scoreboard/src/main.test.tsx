import { describe, expect, it, vi } from 'vitest'
import { StrictMode } from 'react'

const render = vi.fn()
const createRoot = vi.fn(() => ({ render }))

vi.mock('react-dom/client', () => ({ createRoot }))

describe('main', () => {
  it('mounts the app under StrictMode into #root', async () => {
    document.body.innerHTML = '<div id="root"></div>'

    await import('./main')

    expect(createRoot).toHaveBeenCalledTimes(1)
    expect(createRoot).toHaveBeenCalledWith(document.getElementById('root'))
    expect(render).toHaveBeenCalledTimes(1)

    const tree = render.mock.calls[0][0] as { type: unknown; props: { children: unknown } }
    expect(tree.type).toBe(StrictMode)
  })
})