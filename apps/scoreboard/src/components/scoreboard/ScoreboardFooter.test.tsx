import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ScoreboardFooter } from './ScoreboardFooter'

describe('ScoreboardFooter', () => {
  it('passes the handlers and the fullscreen state to the controls', () => {
    const onReset = vi.fn()
    const onSwap = vi.fn()
    const onExport = vi.fn()
    const onToggleFullscreen = vi.fn()
    render(
      <ScoreboardFooter
        isFullscreen={false}
        onReset={onReset}
        onSwap={onSwap}
        onExport={onExport}
        onToggleFullscreen={onToggleFullscreen}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reset scores' }))
    fireEvent.click(screen.getByRole('button', { name: 'Swap sides' }))
    fireEvent.click(screen.getByRole('button', { name: 'Export match' }))
    fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))

    expect(onReset).toHaveBeenCalledTimes(1)
    expect(onSwap).toHaveBeenCalledTimes(1)
    expect(onExport).toHaveBeenCalledTimes(1)
    expect(onToggleFullscreen).toHaveBeenCalledTimes(1)
  })

  it('uses the compact footer sizing rather than the default bar', () => {
    render(
      <ScoreboardFooter
        isFullscreen={false}
        onReset={vi.fn()}
        onSwap={vi.fn()}
        onExport={vi.fn()}
        onToggleFullscreen={vi.fn()}
      />,
    )

    const reset = screen.getByRole('button', { name: 'Reset scores' })
    expect(reset).toHaveClass('px-3', 'py-1')
    expect(reset).not.toHaveClass('h-9')
  })
})