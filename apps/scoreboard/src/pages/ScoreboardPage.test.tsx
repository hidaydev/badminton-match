import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ScoreboardPage from './ScoreboardPage'
import { resetStorageStatus } from '../utils/storage'

function renderPage(store: Record<string, string> = {}) {
  for (const [key, value] of Object.entries(store)) localStorage.setItem(key, value)
  return render(<ScoreboardPage />)
}

const halfOf = (name: string) =>
  screen.getByRole('button', { name: new RegExp(`^${name}, \\d+, tap to score$`) })

const scoreFaces = () =>
  screen.getAllByRole('button', { name: /, \d+, tap to score$/ })

beforeEach(() => {
  resetStorageStatus()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
  Reflect.deleteProperty(navigator, 'storage')
  Reflect.deleteProperty(navigator, 'clipboard')
  Reflect.deleteProperty(navigator, 'share')
  // `fullscreenElement` and the viewport are defined per test; leaving them set
  // makes the next render start in fullscreen or in portrait.
  Object.defineProperty(document, 'fullscreenElement', { value: null, configurable: true })
  Object.defineProperty(window, 'innerWidth', { value: 1024, configurable: true })
  Object.defineProperty(window, 'innerHeight', { value: 768, configurable: true })
})

describe('ScoreboardPage', () => {
  it('adds a point to the half that was tapped and stores it', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(halfOf('Arya'))

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
    expect(within(halfOf('Bowo')).getByText('0')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('1')
    expect(localStorage.getItem('score-blue')).toBe('0')
  })

  it('saturates at 99 and never shows 100', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': '99' })

    fireEvent.click(halfOf('Arya'))

    expect(within(halfOf('Arya')).getByText('99')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('99')
  })

  it('floors the minus control at zero without scoring the half', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(screen.getByRole('button', { name: 'Decrease red score' }))

    expect(within(halfOf('Arya')).getByText('0')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('0')
  })

  it('subtracts one point from a positive score', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': '2' })

    fireEvent.click(screen.getByRole('button', { name: 'Decrease red score' }))

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
  })

  it('floors the blue minus control at zero as well', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-blue': '1' })

    fireEvent.click(screen.getByRole('button', { name: 'Decrease blue score' }))

    expect(within(halfOf('Bowo')).getByText('0')).toBeInTheDocument()
    expect(localStorage.getItem('score-blue')).toBe('0')
  })

  it('resets both sides to zero and writes the zeros', () => {
    renderPage({
      'name-red': 'Arya',
      'name-blue': 'Bowo',
      'score-red': '7',
      'score-blue': '3',
    })

    fireEvent.click(screen.getByRole('button', { name: 'Reset scores' }))

    expect(localStorage.getItem('score-red')).toBe('0')
    expect(localStorage.getItem('score-blue')).toBe('0')
    expect(within(halfOf('Arya')).getByText('0')).toBeInTheDocument()
    expect(within(halfOf('Bowo')).getByText('0')).toBeInTheDocument()
  })

  it('swaps the two halves and keeps their scores with them', () => {
    renderPage({
      'name-red': 'Arya',
      'name-blue': 'Bowo',
      'score-red': '3',
      'score-blue': '1',
    })

    fireEvent.click(screen.getByRole('button', { name: 'Swap sides' }))

    const halves = scoreFaces()
    expect(halves[0]).toHaveAccessibleName('Bowo, 1, tap to score')
    expect(halves[1]).toHaveAccessibleName('Arya, 3, tap to score')
  })

  it('restores stored names, ignores the old colour defaults and falls back to the labels', () => {
    renderPage({ 'name-red': 'Red', 'name-blue': 'Bowo' })

    expect(screen.getByText('RED')).toBeInTheDocument()
    expect(screen.getByText('Bowo')).toBeInTheDocument()
  })

  it('renames a side and persists the new name', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(screen.getByText('Arya'))
    const input = screen.getByLabelText('Red team name')
    fireEvent.change(input, { target: { value: 'Arya P' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(localStorage.getItem('name-red')).toBe('Arya P')
    expect(screen.getByText('Arya P')).toBeInTheDocument()
  })

  it('renames the blue side and persists it on blur', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(screen.getByText('Bowo'))
    const input = screen.getByLabelText('Blue team name')
    fireEvent.change(input, { target: { value: 'Bowo S' } })
    fireEvent.blur(input)

    expect(localStorage.getItem('name-blue')).toBe('Bowo S')
    expect(screen.getByText('Bowo S')).toBeInTheDocument()
  })

  it('does not score when a space is typed into the team name', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(screen.getByText('Arya'))
    const input = screen.getByLabelText('Red team name')
    fireEvent.change(input, { target: { value: 'Red Team' } })
    fireEvent.keyDown(input, { key: ' ' })
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(within(halfOf('Red Team')).getByText('0')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('0')
  })

  it('does not score on Space or Enter on the minus button', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': '2' })

    const minus = screen.getByRole('button', { name: 'Decrease red score' })
    fireEvent.keyDown(minus, { key: ' ' })
    fireEvent.keyDown(minus, { key: 'Enter' })

    expect(within(halfOf('Arya')).getByText('2')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('2')
  })

  it('keeps the space in the team name and leaves the score at zero', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-blue': '5' })

    fireEvent.click(screen.getByText('Arya'))
    const input = screen.getByLabelText('Red team name')
    fireEvent.change(input, { target: { value: 'Red Team' } })

    expect(input).toHaveValue('Red Team')
    expect(screen.getByText('0')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('0')
  })

  it('decreases the score by exactly one when Space activates the minus button', async () => {
    const user = userEvent.setup()
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': '3' })

    const minus = screen.getByRole('button', { name: 'Decrease red score' })
    minus.focus()
    await user.keyboard(' ')

    expect(within(halfOf('Arya')).getByText('2')).toBeInTheDocument()
    expect(localStorage.getItem('score-red')).toBe('2')
  })

  it('says fullscreen is unavailable instead of failing silently', async () => {
    Object.defineProperty(document, 'fullscreenEnabled', { value: false, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    // `toggleFullscreen` awaits the attempt, so the error lands one microtask
    // after the click.
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))
    })

    expect(screen.getByText('Fullscreen not supported on this browser')).toBeInTheDocument()
  })

  it('enters fullscreen, locks landscape and follows the fullscreenchange event', async () => {
    Object.defineProperty(document, 'fullscreenEnabled', { value: true, configurable: true })
    const requestFullscreen = vi.fn(async () => {})
    Object.defineProperty(document.documentElement, 'requestFullscreen', {
      value: requestFullscreen,
      configurable: true,
    })
    Object.defineProperty(screen, 'orientation', {
      value: { lock: vi.fn(async () => {}) },
      configurable: true,
    })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))
    })
    expect(requestFullscreen).toHaveBeenCalledTimes(1)

    Object.defineProperty(document, 'fullscreenElement', {
      value: document.documentElement,
      configurable: true,
    })
    act(() => {
      document.dispatchEvent(new Event('fullscreenchange'))
    })

    expect(screen.getByRole('button', { name: 'Exit fullscreen' })).toBeInTheDocument()
  })

  it('hides the fullscreen error after four seconds', async () => {
    vi.useFakeTimers()
    Object.defineProperty(document, 'fullscreenEnabled', { value: false, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))
    })
    expect(screen.getByText('Fullscreen not supported on this browser')).toBeInTheDocument()

    act(() => {
      vi.advanceTimersByTime(4000)
    })
    expect(screen.queryByText('Fullscreen not supported on this browser')).not.toBeInTheDocument()
  })

  it('rotates the board when the viewport is taller than it is wide', () => {
    const { container } = renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })
    const board = container.querySelector('main') as HTMLElement
    expect(board.getAttribute('style')).not.toContain('rotate(90deg)')

    Object.defineProperty(window, 'innerWidth', { value: 400, configurable: true })
    Object.defineProperty(window, 'innerHeight', { value: 800, configurable: true })
    act(() => {
      window.dispatchEvent(new Event('resize'))
    })

    expect(board.getAttribute('style')).toContain('rotate(90deg)')
  })

  it('ignores a stored score that is not a number', () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': 'abc' })

    expect(within(halfOf('Arya')).getByText('0')).toBeInTheDocument()
  })

  it('asks for persistent storage once on the first nonzero score', async () => {
    const persist = vi.fn(async () => true)
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    expect(persist).not.toHaveBeenCalled()
    fireEvent.click(halfOf('Arya'))
    await act(async () => {})
    fireEvent.click(halfOf('Arya'))
    await act(async () => {})

    expect(persist).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('status')).toHaveTextContent('Scores are saved on this device')
  })

  it('does not ask for persistent storage on load', () => {
    const persist = vi.fn(async () => true)
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo', 'score-red': '3' })

    expect(persist).not.toHaveBeenCalled()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('does not ask for persistent storage while the score stays zero', () => {
    const persist = vi.fn(async () => true)
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(screen.getByRole('button', { name: 'Decrease red score' }))
    fireEvent.click(screen.getByRole('button', { name: 'Reset scores' }))

    expect(persist).not.toHaveBeenCalled()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('keeps scoring when navigator.storage is missing', () => {
    Reflect.deleteProperty(navigator, 'storage')
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(halfOf('Arya'))

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('keeps scoring and notes a denied request when persist rejects', async () => {
    const persist = vi.fn(async () => {
      throw new Error('denied')
    })
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(halfOf('Arya'))
    await act(async () => {})

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Scores may be cleared by the browser')
  })

  it('keeps scoring when persist throws synchronously', async () => {
    const persist = vi.fn(() => {
      throw new Error('blocked')
    })
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(halfOf('Arya'))
    await act(async () => {})

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Scores may be cleared by the browser')
  })

  it('keeps scoring and says scores may be cleared when persistence is not granted', async () => {
    const persist = vi.fn(async () => false)
    Object.defineProperty(navigator, 'storage', { value: { persist }, configurable: true })
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    fireEvent.click(halfOf('Arya'))
    await act(async () => {})

    expect(within(halfOf('Arya')).getByText('1')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Scores may be cleared by the browser')
  })

  it('keeps scoring in memory when localStorage is blocked, and says so', () => {
    const blocked = () => {
      throw new DOMException('blocked', 'SecurityError')
    }
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(blocked)
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(blocked)

    renderPage()
    expect(screen.getByText('RED')).toBeInTheDocument()

    fireEvent.click(halfOf('RED'))

    expect(within(halfOf('RED')).getByText('1')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent(
      'Scores are not being saved on this device',
    )
  })

  it('restores scores from memory after a remount while storage is blocked', () => {
    const blocked = () => {
      throw new DOMException('blocked', 'SecurityError')
    }
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(blocked)
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(blocked)

    const first = renderPage()
    fireEvent.click(halfOf('RED'))
    first.unmount()

    render(<ScoreboardPage />)
    expect(within(halfOf('RED')).getByText('1')).toBeInTheDocument()
  })

  it('exports the four stored keys as JSON so the match can leave the device', async () => {
    const writeText = vi.fn(async (_text: string) => {})
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    renderPage({
      'name-red': 'Arya',
      'name-blue': 'Bowo',
      'score-red': '4',
      'score-blue': '2',
    })

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Export match' }))
    })

    expect(writeText).toHaveBeenCalledTimes(1)
    const exported = JSON.parse(writeText.mock.calls[0][0] as string)
    expect(exported).toEqual({
      'score-red': localStorage.getItem('score-red'),
      'score-blue': localStorage.getItem('score-blue'),
      'name-red': localStorage.getItem('name-red'),
      'name-blue': localStorage.getItem('name-blue'),
    })
    expect(screen.getByText('Match copied to clipboard')).toBeInTheDocument()
  })

  it('says so when the match cannot be exported', async () => {
    renderPage({ 'name-red': 'Arya', 'name-blue': 'Bowo' })

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Export match' }))
    })

    expect(screen.getByText('Could not export the match')).toBeInTheDocument()
  })
})
