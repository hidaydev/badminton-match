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
})
