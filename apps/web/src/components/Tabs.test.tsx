import { useState } from 'react'
import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { Tabs } from './Tabs'

const ITEMS = [
  { id: 'games', label: 'Games' },
  { id: 'standings', label: 'Standings' },
  { id: 'rules', label: 'Rules' },
]

function Harness({ initial = 'games' }: { initial?: string }) {
  const [value, setValue] = useState(initial)
  return <Tabs items={ITEMS} value={value} onChange={setValue} panelId="panel" label="Session" />
}

describe('Tabs', () => {
  it('renders one tablist with only the active tab in the tab order', () => {
    render(<Harness />)

    expect(screen.getAllByRole('tablist')).toHaveLength(1)
    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('tab', { name: 'Standings' })).toHaveAttribute('tabindex', '-1')
    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('aria-selected', 'true')
  })

  it('moves selection and focus with the arrow keys, wrapping at the ends', () => {
    render(<Harness />)

    const games = screen.getByRole('tab', { name: 'Games' })
    games.focus()
    fireEvent.keyDown(games, { key: 'ArrowRight' })

    const standings = screen.getByRole('tab', { name: 'Standings' })
    expect(standings).toHaveAttribute('aria-selected', 'true')
    expect(document.activeElement).toBe(standings)

    fireEvent.keyDown(standings, { key: 'ArrowRight' })
    expect(screen.getByRole('tab', { name: 'Rules' })).toHaveAttribute('aria-selected', 'true')
    fireEvent.keyDown(screen.getByRole('tab', { name: 'Rules' }), { key: 'ArrowRight' })
    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('aria-selected', 'true')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'ArrowLeft' })
    expect(screen.getByRole('tab', { name: 'Rules' })).toHaveAttribute('aria-selected', 'true')
  })

  it('jumps to the first and last tab with Home and End', () => {
    render(<Harness initial="standings" />)

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Standings' }), { key: 'End' })
    expect(screen.getByRole('tab', { name: 'Rules' })).toHaveAttribute('aria-selected', 'true')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Rules' }), { key: 'Home' })
    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('aria-selected', 'true')
  })

  it('points every tab at the panel and lets the caller pick the chip style', () => {
    render(
      <Tabs
        items={ITEMS}
        value="games"
        onChange={() => undefined}
        panelId="panel"
        label="Session"
        tabClassName={(active) => (active ? 'chip-active' : 'chip')}
      />,
    )

    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('aria-controls', 'panel')
    expect(screen.getByRole('tab', { name: 'Games' })).toHaveClass('chip-active')
    expect(screen.getByRole('tab', { name: 'Rules' })).toHaveClass('chip')
  })
})
