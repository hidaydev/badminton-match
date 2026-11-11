import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { TabBar, tabId, tabPanelId } from './TabBar'

const items = [
  { id: 'games', label: 'Games' },
  { id: 'standings', label: 'Standings' },
] as const

type Id = (typeof items)[number]['id']

function setup(value: Id = 'games') {
  const onChange = vi.fn()
  const view = render(
    <TabBar
      items={items}
      value={value}
      onChange={onChange}
      label="Session views"
      idPrefix="session"
      tabClassName={(_item, selected) => (selected ? 'is-selected' : '')}
    />,
  )
  return { onChange, view }
}

describe('TabBar', () => {
  it('renders one tab per item with the roving tab stop on the selected one', () => {
    setup()

    const tabs = screen.getAllByRole('tab')
    expect(tabs).toHaveLength(2)
    expect(tabs[0]).toHaveAttribute('aria-selected', 'true')
    expect(tabs[0]).toHaveAttribute('tabindex', '0')
    expect(tabs[1]).toHaveAttribute('aria-selected', 'false')
    expect(tabs[1]).toHaveAttribute('tabindex', '-1')
    expect(tabs[0]).toHaveAttribute('id', tabId('session', 'games'))
    expect(tabs[0]).toHaveAttribute('aria-controls', tabPanelId('session'))
    expect(screen.getByRole('tablist', { name: 'Session views' })).toBeInTheDocument()
  })

  it('changes the view on a click and on the arrow keys, and wraps around', () => {
    const { onChange } = setup()

    fireEvent.click(screen.getByRole('tab', { name: 'Standings' }))
    expect(onChange).toHaveBeenLastCalledWith('standings')

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'ArrowRight' })
    expect(onChange).toHaveBeenLastCalledWith('standings')

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'ArrowLeft' })
    expect(onChange).toHaveBeenLastCalledWith('standings')
  })

  it('jumps to the first and last tab with Home and End', () => {
    const { onChange } = setup('standings')

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'Home' })
    expect(onChange).toHaveBeenLastCalledWith('games')

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'End' })
    expect(onChange).toHaveBeenLastCalledWith('standings')
  })

  it('moves the focus to the tab it selected, and ignores any other key', () => {
    setup()

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'ArrowRight' })
    expect(document.activeElement).toBe(screen.getByRole('tab', { name: 'Standings' }))

    fireEvent.keyDown(screen.getByRole('tablist'), { key: 'Tab' })
    expect(document.activeElement).toBe(screen.getByRole('tab', { name: 'Standings' }))
  })
})
