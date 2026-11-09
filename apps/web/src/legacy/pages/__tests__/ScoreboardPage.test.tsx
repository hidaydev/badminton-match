import { beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { t } from '@/i18n'
import { validateScore } from '../../utils/scoreValidation'
import ScoreboardPage, { type OverlayConfig } from '../ScoreboardPage'

// The overlay is the write path: a match score the page may not change while a
// save is in flight, and may not commit twice. Standalone mode is the tap
// counter the home card opens, and it only owns localStorage.
function renderScoreboard(over: Partial<OverlayConfig> = {}) {
  const onClose = vi.fn()
  const overlay: OverlayConfig = {
    matchId: 'm1',
    pairAName: 'Arya/Bima',
    pairBName: 'Cici/Dewi',
    initialScoreA: 5,
    initialScoreB: 7,
    onSave: async () => {},
    onClose,
    ...over,
  }
  const view = render(
    <MemoryRouter>
      <ScoreboardPage overlay={overlay} />
    </MemoryRouter>,
  )
  return { ...view, overlay, onClose }
}

function renderStandalone() {
  return render(
    <MemoryRouter>
      <ScoreboardPage />
    </MemoryRouter>,
  )
}

function scoreFace(side: 'Red' | 'Blue', score: number) {
  return screen.getByRole('button', { name: t('scoreboard.score', { side, score }) })
}

function saveControl() {
  return screen.getByRole('button', { name: 'Save Score' })
}

describe('ScoreboardPage overlay save', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('refuses a tied score with the validation message and does not save', async () => {
    const onSave = vi.fn(async () => {})
    renderScoreboard({ initialScoreA: 7, initialScoreB: 7, onSave })

    fireEvent.click(saveControl())

    const refusal = validateScore(7, 7)
    expect(refusal).not.toBeNull()
    expect(await screen.findByText(refusal as string)).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
    // The sheet stays where it was: no close, and no discard prompt either.
    expect(screen.queryByText('Discard score?')).not.toBeInTheDocument()
  })

  it('reports a rejected save and leaves the overlay open', async () => {
    const onSave = vi.fn(async () => {
      throw new Error('network down')
    })
    const errorLog = vi.spyOn(console, 'error').mockImplementation(() => {})
    const { onClose } = renderScoreboard({ initialScoreA: 5, initialScoreB: 7, onSave })

    fireEvent.click(saveControl())

    expect(await screen.findByText('Save failed: network down')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    expect(errorLog).toHaveBeenCalled()
    // The control is usable again, so the retry is the user's choice.
    await waitFor(() => expect(saveControl()).toBeEnabled())
  })

  it('ignores a score tap while a save is in flight', async () => {
    const onSave = vi.fn(() => new Promise<void>(() => {}))
    renderScoreboard({ initialScoreA: 5, initialScoreB: 7, onSave })

    fireEvent.click(saveControl())
    await screen.findByRole('button', { name: /Saving/ })

    fireEvent.click(scoreFace('Red', 5))
    fireEvent.click(scoreFace('Blue', 7))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(scoreFace('Red', 5)).toBeInTheDocument()
    expect(scoreFace('Blue', 7)).toBeInTheDocument()
  })

  it('disables Save while saving so a second tap cannot save twice', async () => {
    let release = () => {}
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const onSave = vi.fn(() => gate)
    const { onClose } = renderScoreboard({ initialScoreA: 5, initialScoreB: 7, onSave })

    fireEvent.click(saveControl())
    const saving = await screen.findByRole('button', { name: /Saving/ })
    expect(saving).toBeDisabled()

    fireEvent.click(saving)
    expect(onSave).toHaveBeenCalledTimes(1)

    await act(async () => {
      release()
      await gate
    })
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
    expect(onSave).toHaveBeenCalledTimes(1)
  })

  it('saves the two scores and closes on success', async () => {
    const onSave = vi.fn(async () => {})
    const { onClose } = renderScoreboard({ initialScoreA: 9, initialScoreB: 4, onSave })

    fireEvent.click(saveControl())

    await waitFor(() => expect(onSave).toHaveBeenCalledWith(9, 4))
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })
})

describe('ScoreboardPage score bounds', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('saturates the score at 99 and floors it at 0', () => {
    const high = renderScoreboard({ initialScoreA: 99, initialScoreB: 99 })
    fireEvent.click(scoreFace('Red', 99))
    fireEvent.click(scoreFace('Blue', 99))
    expect(scoreFace('Red', 99)).toBeInTheDocument()
    expect(scoreFace('Blue', 99)).toBeInTheDocument()
    high.unmount()

    renderScoreboard({ initialScoreA: 0, initialScoreB: 0 })
    fireEvent.click(screen.getByRole('button', { name: t('scoreboard.decrease', { side: 'Red' }) }))
    fireEvent.click(screen.getByRole('button', { name: t('scoreboard.decrease', { side: 'Blue' }) }))
    expect(scoreFace('Red', 0)).toBeInTheDocument()
    expect(scoreFace('Blue', 0)).toBeInTheDocument()
  })
})

describe('ScoreboardPage standalone mode', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('writes each side score to localStorage under its key', async () => {
    renderStandalone()

    fireEvent.click(scoreFace('Red', 0))
    fireEvent.click(scoreFace('Blue', 0))

    await waitFor(() => {
      expect(window.localStorage.getItem('score-red')).toBe('1')
      expect(window.localStorage.getItem('score-blue')).toBe('1')
    })
  })
})