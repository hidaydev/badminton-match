import { describe, expect, it } from 'vitest'
import { render } from '@testing-library/react'
import { titleKeyForPath, usePageTitle } from './usePageTitle'
import { t } from '../i18n'

function Probe({ path }: { path: Parameters<typeof titleKeyForPath>[0] }) {
  usePageTitle(titleKeyForPath(path))
  return null
}

describe('titleKeyForPath', () => {
  it('names the screen a legacy path is on', () => {
    expect(titleKeyForPath('/')).toBe('nav.home')
    expect(titleKeyForPath('/sessions')).toBe('sessions.title')
    expect(titleKeyForPath('/rankings')).toBe('rankings.title')
    expect(titleKeyForPath('/players')).toBe('players.title')
    expect(titleKeyForPath('/tournaments')).toBe('tournaments.title')
    expect(titleKeyForPath('/settings')).toBe('admin.title')
  })

  it('tells the session wizard steps apart', () => {
    expect(titleKeyForPath('/session/new')).toBe('wizard.setup.title')
    expect(titleKeyForPath('/session/players')).toBe('wizard.players.title')
    expect(titleKeyForPath('/session/constraints')).toBe('wizard.constraints.title')
    expect(titleKeyForPath('/session/generate')).toBe('wizard.generate.title')
  })

  it('reads a detail path as the screen it is, not its list', () => {
    expect(titleKeyForPath('/players/p1')).toBe('player.title')
    expect(titleKeyForPath('/tournaments/t1')).toBe('tournaments.title')
  })

  it('falls back to home for a path it does not know', () => {
    expect(titleKeyForPath('/a-screen-from-a-newer-build')).toBe('nav.home')
  })
})

describe('usePageTitle', () => {
  it('writes "<screen> · Majadu"', () => {
    render(<Probe path="/rankings" />)

    expect(document.title).toBe(`${t('rankings.title')} · ${t('app.name')}`)
  })

  it('rewrites the title when the screen changes', () => {
    const { rerender } = render(<Probe path="/rankings" />)
    rerender(<Probe path="/sessions" />)

    expect(document.title).toBe(`${t('sessions.title')} · ${t('app.name')}`)
  })
})
