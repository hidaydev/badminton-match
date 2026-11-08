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

describe('ScoreboardSide', () => {
  it('shows the score and the name, and fills the background by side', () => {
    const { container } = render(<ScoreboardSide {...props()} />)

    expect(screen.getByText('7')).toBeInTheDocument()
    expect(screen.getByText('Arya')).toBeInTheDocument()
    expect(container.firstElementChild?.getAttribute('style')).toContain('rgb(185, 28, 28)')
  })

  it('scores on click, on Enter and on Space, and ignores other keys', () => {
    const onScore = vi.fn()
    render(<ScoreboardSide {...props({ onScore })} />)
    const half = screen.getByRole('button', { name: /Arya|7/ })

    fireEvent.click(half)
    fireEvent.keyDown(half, { key: 'Enter' })
    fireEvent.keyDown(half, { key: ' ' })
    fireEvent.keyDown(half, { key: 'a' })

    expect(onScore).toHaveBeenCalledTimes(3)
  })

  it('calls onMinus with the click and does not score when the handler stops it', () => {
    // The page's handlers call `stopPropagation` so a minus tap cannot also add
    // a point. The component only forwards the event, so the test models the
    // real caller instead of hoping the bubble does not happen.
    const onScore = vi.fn()
    const onMinus = vi.fn((event: React.MouseEvent) => event.stopPropagation())
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