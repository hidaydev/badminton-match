import { createElement, memo } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import type { ScoreboardSideProps } from '@majadu/scoreboard-ui'

const renders = { red: 0, blue: 0 }

vi.mock('@majadu/scoreboard-ui', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@majadu/scoreboard-ui')>()
  const Counted = memo(function Counted(props: ScoreboardSideProps) {
    renders[props.side] += 1
    return createElement(actual.ScoreboardSide, props)
  })
  return { ...actual, ScoreboardSide: Counted }
})

const { default: ScoreboardPage } = await import('./ScoreboardPage')

describe('ScoreboardPage rendering', () => {
  it('does not re-render the other half while a name is typed', () => {
    renders.red = 0
    renders.blue = 0
    render(createElement(ScoreboardPage))

    const blueAtStart = renders.blue
    expect(renders.red).toBeGreaterThan(0)
    expect(blueAtStart).toBeGreaterThan(0)

    fireEvent.click(screen.getByText('RED'))
    const input = screen.getByLabelText('Red team name')
    fireEvent.change(input, { target: { value: 'Arya' } })

    expect(renders.blue).toBe(blueAtStart)
    expect(screen.getByDisplayValue('Arya')).toBeInTheDocument()
  })
})
