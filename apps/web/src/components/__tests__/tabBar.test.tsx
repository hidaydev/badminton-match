import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { TabBar, tabId, tabPanelId } from '../TabBar'

const items = [
  { id: 'games', label: 'Games' },
  { id: 'standings', label: 'Standings' },
  { id: 'awards', label: 'Awards' },
] as const

function renderBar(value: string, onChange = vi.fn()) {
  render(
    <TabBar
      items={items}
      value={value as 'games'}
      onChange={onChange}
      label="Views"
      idPrefix="demo"
      className="flex"
      tabClassName={(_item, selected) => (selected ? 'selected' : '')}
    />,
  )
  return onChange
}

describe('TabBar', () => {
  it('marks the selected tab and keeps a roving tab stop', () => {
    renderBar('standings')

    expect(screen.getByRole('tab', { name: 'Games' })).toHaveAttribute('tabindex', '-1')
    expect(screen.getByRole('tab', { name: 'Standings' })).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('tab', { name: 'Standings' })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tab', { name: 'Standings' })).toHaveAttribute(
      'aria-controls',
      tabPanelId('demo'),
    )
    expect(screen.getByRole('tab', { name: 'Standings' })).toHaveAttribute(
      'id',
      tabId('demo', 'standings'),
    )
  })

  it('wraps with the arrow keys and jumps with Home and End', () => {
    const onChange = renderBar('games')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'ArrowLeft' })
    expect(onChange).toHaveBeenLastCalledWith('awards')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'ArrowRight' })
    expect(onChange).toHaveBeenLastCalledWith('standings')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'End' })
    expect(onChange).toHaveBeenLastCalledWith('awards')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'Home' })
    expect(onChange).toHaveBeenLastCalledWith('games')
  })

  it('ignores keys that are not part of the pattern', () => {
    const onChange = renderBar('games')

    fireEvent.keyDown(screen.getByRole('tab', { name: 'Games' }), { key: 'Tab' })

    expect(onChange).not.toHaveBeenCalled()
  })
})
