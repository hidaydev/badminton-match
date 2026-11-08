import { beforeEach, describe, expect, it } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { mockFetch } from '../../../test/fetchMock'
import { t } from '../../../i18n'
import { LegacySlugProvider } from '../../router'
import { prepareCommunityDraft, useStore } from '../../store'
import PlayersPage from '../PlayersPage'

const ROSTER = 'GET /api/c/acme/players?limit=1000'

function seed(names: string[]) {
  act(() => {
    for (const name of names) {
      useStore.getState().addPlayer({ name, gender: 'M', tier: 2 })
    }
  })
}

function renderPlayers() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={['/c/acme/session/players']}>
        <LegacySlugProvider slug="acme">
          <Routes>
            <Route path="/c/acme/session/players" element={<PlayersPage />} />
          </Routes>
        </LegacySlugProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

function removeButtons() {
  return screen.getAllByRole('button', { name: t('wizard.players.remove') })
}

describe('PlayersPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme')
    prepareCommunityDraft('acme')
    useStore.getState().resetSession()
    // The canonical roster read fires on mount and only feeds autofill here.
    mockFetch({ [ROSTER]: () => ({ body: { items: [] } }) })
  })

  it('marks the count pill complete only when the roster reaches the target', () => {
    seed(['Ani', 'Budi', 'Candra', 'Dewi', 'Eka', 'Fajar', 'Gita'])

    renderPlayers()

    const short = screen.getByText('7/8')
    expect(short.className).not.toContain('text-emerald-400')
    expect(screen.getByText('1 more player needed')).toBeInTheDocument()

    act(() => useStore.getState().addPlayer({ name: 'Hana', gender: 'F', tier: 2 }))

    const complete = screen.getByText('8/8')
    expect(complete.className).toContain('text-emerald-400')
    expect(screen.queryByText('1 more player needed')).not.toBeInTheDocument()
  })

  it('appends the typed player after the existing names', () => {
    seed(['Ani'])

    renderPlayers()

    fireEvent.click(screen.getByRole('button', { name: '+ Add Player' }))
    fireEvent.change(screen.getByPlaceholderText('Player name'), { target: { value: 'Budi' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add' }))

    expect(screen.getByText('Ani')).toBeInTheDocument()
    expect(screen.getByText('Budi')).toBeInTheDocument()
    expect(removeButtons()).toHaveLength(2)
    expect(useStore.getState().players.map((p) => p.name)).toEqual(['Ani', 'Budi'])
  })

  it('adds nothing once the roster is at the session target', () => {
    seed(['Ani', 'Budi', 'Candra', 'Dewi', 'Eka', 'Fajar', 'Gita', 'Hana'])

    renderPlayers()

    expect(screen.getByRole('button', { name: '+ Add Player' })).toBeDisabled()
    const tbd = screen.getByRole('button', { name: '+ TBD' })
    expect(tbd).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Bulk' })).toBeDisabled()

    fireEvent.click(tbd)

    expect(screen.queryByPlaceholderText('Player name')).not.toBeInTheDocument()
    expect(removeButtons()).toHaveLength(8)
    expect(useStore.getState().players).toHaveLength(8)

    // The controls above are disabled, so the cap itself is the last line of
    // defence: the draft refuses the ninth player even when it is asked
    // directly.
    act(() => useStore.getState().addPlayer({ name: 'Late', gender: 'M', tier: 2 }))
    expect(useStore.getState().players).toHaveLength(8)
    expect(removeButtons()).toHaveLength(8)
  })
})