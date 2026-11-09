import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom'
import { RouteChange } from '../RouteChange'

function Screens() {
  const navigate = useNavigate()
  return (
    <Routes>
      <Route
        path="/list"
        element={
          <main>
            <h1>Players</h1>
            <button onClick={() => navigate('/player')}>Open player</button>
          </main>
        }
      />
      <Route
        path="/player"
        element={
          <main>
            <h1>Ani</h1>
            <button onClick={() => navigate(-1)}>Back</button>
          </main>
        }
      />
    </Routes>
  )
}

function setScroll(offset: number) {
  Object.defineProperty(window, 'scrollY', { value: offset, configurable: true })
  window.dispatchEvent(new Event('scroll'))
}

describe('RouteChange', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('starts a pushed screen at the top and focuses its heading', () => {
    const scrollTo = vi.fn()
    vi.stubGlobal('scrollTo', scrollTo)
    render(
      <MemoryRouter initialEntries={['/list']}>
        <RouteChange />
        <Screens />
      </MemoryRouter>,
    )

    setScroll(480)
    fireEvent.click(screen.getByRole('button', { name: 'Open player' }))

    expect(scrollTo).toHaveBeenLastCalledWith(0, 0)
    expect(screen.getByRole('heading', { name: 'Ani' })).toBe(document.activeElement)
  })

  it('restores the list offset when going back', () => {
    const scrollTo = vi.fn()
    vi.stubGlobal('scrollTo', scrollTo)
    render(
      <MemoryRouter initialEntries={['/list']}>
        <RouteChange />
        <Screens />
      </MemoryRouter>,
    )

    setScroll(480)
    fireEvent.click(screen.getByRole('button', { name: 'Open player' }))
    setScroll(0)
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))

    expect(scrollTo).toHaveBeenLastCalledWith(0, 480)
  })
})
