import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ScoreboardSide } from './ScoreboardSide'
import type { ScoreboardSideProps } from './ScoreboardSide'

function props(overrides: Partial<ScoreboardSideProps> = {}): ScoreboardSideProps {
  return {
    side: 'red',
    score: 7,
    displayName: 'Arya',
    editValue: 'Arya',
    isEditing: false,
    isPop: false,
    isOverlay: false,
    onScore: vi.fn(),
    onMinus: vi.fn(),
    onNameChange: vi.fn(),
    onStartEditing: vi.fn(),
    onStopEditing: vi.fn(),
    ...overrides,
  }
}

const scoreButton = (name = 'Arya', score = 7) =>
  screen.getByRole('button', { name: `${name}, ${score}, tap to score` })

describe('ScoreboardSide', () => {
  it('shows the score and the name, and fills the background by side', () => {
    const { container } = render(<ScoreboardSide {...props()} />)

    expect(screen.getByText('7')).toBeInTheDocument()
    expect(screen.getByText('Arya')).toBeInTheDocument()
    expect(container.firstElementChild?.getAttribute('style')).toContain('rgb(185, 28, 28)')
  })

  it('keeps the visible words inside the accessible name', () => {
    render(<ScoreboardSide {...props()} />)
    // axe joins adjacent text nodes without a separator, so the hint needs a
    // word boundary of its own; without it the visible text reads "7tap to
    // score" and the label no longer contains what the reader can see.
    expect(scoreButton()).toHaveTextContent(/^7 tap to score$/)
  })

  it('spreads no role=button and no tab stop outside the real controls', () => {
    const { container } = render(<ScoreboardSide {...props()} />)

    expect(container.querySelector('[role="button"]')).toBeNull()
    expect(container.querySelector('[tabindex]')).toBeNull()
  })

  it('scores on click of the score face', () => {
    const onScore = vi.fn()
    render(<ScoreboardSide {...props({ onScore })} />)

    fireEvent.click(scoreButton())

    expect(onScore).toHaveBeenCalledTimes(1)
  })

  it('does not score while typing a space or pressing Enter in the name input', () => {
    const onScore = vi.fn()
    render(<ScoreboardSide {...props({ isEditing: true, onScore })} />)

    const input = screen.getByLabelText('Red team name')
    fireEvent.change(input, { target: { value: 'Red Team' } })
    fireEvent.keyDown(input, { key: ' ' })
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(onScore).not.toHaveBeenCalled()
  })

  it('does not score on Space or Enter on the minus button', () => {
    const onScore = vi.fn()
    render(<ScoreboardSide {...props({ onScore })} />)

    const minus = screen.getByRole('button', { name: 'Decrease red score' })
    fireEvent.keyDown(minus, { key: ' ' })
    fireEvent.keyDown(minus, { key: 'Enter' })

    expect(onScore).not.toHaveBeenCalled()
  })

  it('calls onMinus with the click and does not score', () => {
    const onScore = vi.fn()
    const onMinus = vi.fn()
    render(<ScoreboardSide {...props({ onScore, onMinus })} />)

    fireEvent.click(screen.getByRole('button', { name: 'Decrease red score' }))

    expect(onMinus).toHaveBeenCalledTimes(1)
    expect(onMinus.mock.calls[0][0]).toHaveProperty('type', 'click')
    expect(onScore).not.toHaveBeenCalled()
  })

  it('labels the minus control per side', () => {
    render(<ScoreboardSide {...props({ side: 'blue', displayName: 'Bowo' })} />)
    expect(screen.getByRole('button', { name: 'Decrease blue score' })).toBeInTheDocument()
  })

  it('edits the name through an input with a per-side label', () => {
    const onNameChange = vi.fn()
    const onStopEditing = vi.fn()
    render(
      <ScoreboardSide
        {...props({ isEditing: true, onNameChange, onStopEditing })}
      />,
    )

    const input = screen.getByLabelText('Red team name')
    expect(input).toHaveValue('Arya')
    fireEvent.change(input, { target: { value: 'Arya P' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    fireEvent.blur(input)

    expect(onNameChange).toHaveBeenCalledWith('Arya P')
    expect(onStopEditing).toHaveBeenCalledTimes(2)
  })

  it('starts editing when the name is tapped', () => {
    const onStartEditing = vi.fn()
    render(<ScoreboardSide {...props({ onStartEditing })} />)

    fireEvent.click(screen.getByText('Arya'))
    expect(onStartEditing).toHaveBeenCalledTimes(1)
  })

  it('renders a read-only badge in overlay mode, with no input and no edit', () => {
    const onStartEditing = vi.fn()
    render(<ScoreboardSide {...props({ isOverlay: true, onStartEditing })} />)

    expect(screen.queryByLabelText('Red team name')).not.toBeInTheDocument()
    fireEvent.click(screen.getByText('Arya'))
    expect(onStartEditing).not.toHaveBeenCalled()
  })

  it('scales the score while the pop flag is set', () => {
    const { rerender } = render(<ScoreboardSide {...props({ isPop: true })} />)
    expect(screen.getByText('7')).toHaveStyle({ transform: 'scale(1.1)' })

    rerender(<ScoreboardSide {...props({ isPop: false })} />)
    expect(screen.getByText('7')).toHaveStyle({ transform: 'scale(1)' })
  })
})
