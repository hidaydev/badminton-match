import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ScoreboardFooter } from '@majadu/scoreboard-ui'
import { SCOREBOARD_LABELS } from '../scoreboardLabels'

function renderFooter(overrides: Partial<Parameters<typeof ScoreboardFooter>[0]> = {}) {
  const handlers = {
    onReset: vi.fn(),
    onSwap: vi.fn(),
    onExport: vi.fn(),
    onToggleFullscreen: vi.fn(),
    ...overrides,
  }
  render(
    <ScoreboardFooter
      labels={SCOREBOARD_LABELS}
      isFullscreen={overrides.isFullscreen ?? false}
      {...handlers}
    />,
  )
  return handlers
}

describe('ScoreboardFooter', () => {
  it('passes the handlers and the fullscreen state to the controls', () => {
    const handlers = renderFooter()

    fireEvent.click(screen.getByRole('button', { name: 'Reset scores' }))
    fireEvent.click(screen.getByRole('button', { name: 'Swap sides' }))
    fireEvent.click(screen.getByRole('button', { name: 'Export match' }))
    fireEvent.click(screen.getByRole('button', { name: 'Enter fullscreen' }))

    expect(handlers.onReset).toHaveBeenCalledTimes(1)
    expect(handlers.onSwap).toHaveBeenCalledTimes(1)
    expect(handlers.onExport).toHaveBeenCalledTimes(1)
    expect(handlers.onToggleFullscreen).toHaveBeenCalledTimes(1)
  })

  it('uses the compact footer sizing rather than the default bar', () => {
    renderFooter()

    const reset = screen.getByRole('button', { name: 'Reset scores' })
    expect(reset).toHaveClass('px-3', 'py-1')
    expect(reset).not.toHaveClass('h-9')
  })

  it('omits the export control when the caller has nowhere to export to', () => {
    renderFooter({ onExport: undefined })

    expect(screen.queryByRole('button', { name: 'Export match' })).not.toBeInTheDocument()
  })
})
