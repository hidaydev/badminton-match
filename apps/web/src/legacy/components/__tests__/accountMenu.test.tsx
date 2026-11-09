import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import App from '../../../App'
import { t } from '../../../i18n'
import { mockFetch } from '../../../test/fetchMock'

const membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

function renderHome() {
  mockFetch({
    'GET /api/auth/me': () => ({
      body: { id: 'u1', displayName: 'Ada', platformOwner: false },
    }),
    'GET /api/communities': () => ({ body: { items: [membership] } }),
    'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
    'GET /api/c/acme/sessions?limit=100&offset=0': () => ({
      body: { items: [], total: 0, nextCursor: '' },
    }),
    'GET /api/c/acme/players?mine=1': () => ({ body: { items: [] } }),
  })
  window.history.replaceState({}, '', '/c/acme')
  return render(<App />)
}

async function openMenu() {
  const trigger = await screen.findByRole('button', { name: t('shell.account') })
  fireEvent.click(trigger)
  return { trigger, menu: screen.getByRole('menu', { name: t('shell.account') }) }
}

function items(): HTMLElement[] {
  return screen.getAllByRole('menuitem')
}

describe('account menu keyboard', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('moves focus to the first item when it opens', async () => {
    renderHome()

    await openMenu()

    expect(items()[0]).toBe(document.activeElement)
  })

  it('cycles with the arrow keys and jumps with Home and End', async () => {
    renderHome()

    const { menu } = await openMenu()
    fireEvent.keyDown(menu, { key: 'ArrowDown' })
    expect(items()[1]).toBe(document.activeElement)

    fireEvent.keyDown(menu, { key: 'ArrowUp' })
    fireEvent.keyDown(menu, { key: 'ArrowUp' })
    expect(items()[items().length - 1]).toBe(document.activeElement)

    fireEvent.keyDown(menu, { key: 'Home' })
    expect(items()[0]).toBe(document.activeElement)

    fireEvent.keyDown(menu, { key: 'End' })
    expect(items()[items().length - 1]).toBe(document.activeElement)
  })

  it('closes on Escape and hands focus back to the trigger', async () => {
    renderHome()

    const { trigger, menu } = await openMenu()
    fireEvent.keyDown(menu, { key: 'Escape' })

    expect(screen.queryByRole('menu')).toBeNull()
    expect(document.activeElement).toBe(trigger)
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
  })

  it('closes when Tab leaves the menu', async () => {
    renderHome()

    const { menu } = await openMenu()
    fireEvent.keyDown(menu, { key: 'Tab' })

    expect(screen.queryByRole('menu')).toBeNull()
  })
})
