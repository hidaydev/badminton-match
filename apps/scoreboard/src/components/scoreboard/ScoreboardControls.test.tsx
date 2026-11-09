import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ScoreboardControls } from './ScoreboardControls'

function renderControls(overrides: Partial<Parameters<typeof ScoreboardControls>[0]> = {}) {
  const handlers = {
    onReset: vi.fn(),
    onSwap: vi.fn(),
    onExport: vi.fn(),
    onToggleFullscreen: vi.fn(),
    ...overrides,
  }
  render(
    <ScoreboardControls
      isFullscreen={overrides.isFullscreen ?? false}
      buttonClassName={overrides.buttonClassName}
      {...handlers}
    />,
  )
  return handlers
}

describe('ScoreboardControls', () => {
  it('exposes four labelled controls and calls each handler', () => {
    const handlers = renderControls()

    fireEvent.click(screen.getByRole('button', { name: 'Reset scores' }))
    fireEvent.click(screen.getByRole('button', { name: 'Swap sides' }))
    fireEvent.click(screen.getByRole('button', { name: 'Export match' }))
    fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))

    expect(handlers.onReset).toHaveBeenCalledTimes(1)
    expect(handlers.onSwap).toHaveBeenCalledTimes(1)
    expect(handlers.onExport).toHaveBeenCalledTimes(1)
    expect(handlers.onToggleFullscreen).toHaveBeenCalledTimes(1)
  })

  it('renames the fullscreen control and swaps its glyph by state', () => {
    renderControls({ isFullscreen: true })

    const exit = screen.getByRole('button', { name: 'Exit fullscreen' })
    expect(exit).toHaveTextContent('⊠')
    expect(screen.queryByRole('button', { name: 'Enter fullscreen' })).not.toBeInTheDocument()
  })

  it('appends the caller layout classes to the shared button classes', () => {
    renderControls({ buttonClassName: 'px-3 h-9 flex items-center' })

    const reset = screen.getByRole('button', { name: 'Reset scores' })
    expect(reset).toHaveClass('px-3', 'h-9', 'flex', 'items-center')
    expect(reset).toHaveClass('rounded-lg')
    expect(reset.getAttribute('style')).toContain('rgba(255, 255, 255, 0.06)')
  })
})