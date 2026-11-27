import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom'
import { RouteChange } from './RouteChange'

let scrollY = 0
let scrollTo: ReturnType<typeof vi.fn>

function Screen({ title }: { title: string }) {
  return (
    <main>
      <h1>{title}</h1>
    </main>
  )
}

function Nav() {
  const navigate = useNavigate()
  return (
    <>
      <button type="button" onClick={() => navigate('/two')}>
        go
      </button>
      <button type="button" onClick={() => navigate(-1)}>
        back
      </button>
      <button type="button" onClick={() => navigate(1)}>
        forward
      </button>
    </>
  )
}

function renderAt(path: string, ui = <Screen title="One" />) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <RouteChange />
      <Nav />
      <Routes>
        <Route path="*" element={ui} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  scrollY = 0
  Object.defineProperty(window, 'scrollY', { configurable: true, get: () => scrollY })
  scrollTo = vi.fn()
  Object.defineProperty(window, 'scrollTo', { configurable: true, writable: true, value: scrollTo })
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe('RouteChange', () => {
  it('leaves the first render alone so the browser keeps its own restoration', () => {
    renderAt('/one')

    expect(scrollTo).not.toHaveBeenCalled()
    expect(document.activeElement).toBe(document.body)
  })

  it('starts a push at the top and focuses the screen heading', () => {
    renderAt('/one')

    fireEvent.click(screen.getByRole('button', { name: 'go' }))

    expect(scrollTo).toHaveBeenCalledWith(0, 0)
    const heading = screen.getByRole('heading', { name: 'One' })
    expect(heading.getAttribute('tabindex')).toBe('-1')
    expect(document.activeElement).toBe(heading)
  })

  it('restores the offset of the entry a pop returns to, and tracks the scroll', () => {
    renderAt('/one')

    scrollY = 240
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })

    fireEvent.click(screen.getByRole('button', { name: 'go' }))
    expect(scrollTo).toHaveBeenLastCalledWith(0, 0)

    scrollTo.mockClear()
    fireEvent.click(screen.getByRole('button', { name: 'back' }))

    expect(scrollTo).toHaveBeenCalledWith(0, 240)
  })

  it('falls back to the layout main when the screen has no heading', () => {
    renderAt(
      '/one',
      <main>
        <p>No heading here</p>
      </main>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'go' }))

    expect(document.activeElement).toBe(screen.getByRole('main'))
  })

  it('does nothing when the screen has neither a heading nor a main', () => {
    renderAt('/one', <p>Bare</p>)

    expect(() => fireEvent.click(screen.getByRole('button', { name: 'go' }))).not.toThrow()
    expect(document.activeElement).toBe(document.body)
  })

  // MAJ-15: the destination clamps the offset as soon as it renders shorter
  // than where the user was, and that clamp is a scroll event. Recording it
  // would make Back from a short screen land at the clamp, not at the row the
  // user actually left.
  it('remembers the offset the user left even when the next screen is shorter', () => {
    renderAt('/one')

    scrollY = 800
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })
    fireEvent.click(screen.getByRole('button', { name: 'go' }))

    // The short screen: the browser clamps the scroll and says so.
    scrollY = 73
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })

    scrollTo.mockClear()
    fireEvent.click(screen.getByRole('button', { name: 'back' }))

    expect(scrollTo).toHaveBeenCalledWith(0, 800)
  })

  it('takes the offset at pointerdown, before the destination can clamp it', () => {
    renderAt('/one')

    scrollY = 640
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })
    act(() => {
      document.dispatchEvent(new Event('pointerdown', { bubbles: true }))
    })
    // A clamp that arrives after the press but before the router swaps.
    scrollY = 40
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })

    fireEvent.click(screen.getByRole('button', { name: 'go' }))
    scrollTo.mockClear()
    fireEvent.click(screen.getByRole('button', { name: 'back' }))

    expect(scrollTo).toHaveBeenCalledWith(0, 640)
  })

  it('keeps the last known offset when a pop arrives already clamped', () => {
    renderAt('/one')

    scrollY = 512
    act(() => {
      window.dispatchEvent(new Event('scroll'))
    })
    fireEvent.click(screen.getByRole('button', { name: 'go' }))

    // Going forward: the browser fires popstate with the offset already
    // reduced to the destination's height.
    scrollY = 90
    act(() => {
      window.dispatchEvent(new Event('popstate'))
    })

    scrollTo.mockClear()
    fireEvent.click(screen.getByRole('button', { name: 'back' }))

    expect(scrollTo).toHaveBeenCalledWith(0, 512)
  })
})
