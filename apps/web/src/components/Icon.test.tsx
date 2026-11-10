import { render } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import Icon, { type IconName } from './Icon'

const NAMES: IconName[] = [
  'plus', 'sessions', 'history', 'ratings', 'scoreboard', 'tournament', 'admin',
  'post', 'download', 'download-tray', 'play', 'unlock', 'players', 'season',
  'camera', 'chevron-left', 'chevron-right', 'check', 'close', 'refresh', 'sync',
  'rotate', 'share', 'trash', 'user', 'list',
]

describe('Icon', () => {
  it.each(NAMES)('draws %s', (name) => {
    const { container } = render(<Icon name={name} />)
    const svg = container.querySelector('svg')
    expect(svg).not.toBeNull()
    expect(svg?.getAttribute('width')).toBe('20')
    expect(svg?.getAttribute('viewBox')).toBe('0 0 24 24')
    expect(svg?.getAttribute('aria-hidden')).toBe('true')
  })

  it('takes its size from the caller', () => {
    const { container } = render(<Icon name="check" size={14} />)
    expect(container.querySelector('svg')?.getAttribute('height')).toBe('14')
  })

  it('keeps one stroke weight so adjacent glyphs match', () => {
    const { container } = render(<Icon name="sync" />)
    expect(container.querySelector('svg')?.getAttribute('stroke-width')).toBe('1.8')
  })

  it('renders nothing for a name outside the set', () => {
    const { container } = render(<Icon name={'nope' as IconName} />)
    expect(container.querySelector('svg')).toBeNull()
  })
})
