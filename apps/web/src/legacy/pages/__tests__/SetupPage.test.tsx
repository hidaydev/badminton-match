import { beforeEach, describe, expect, it } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import type { ScoringPreset } from '../../../community/api'
import { mockFetch } from '../../../test/fetchMock'
import { LegacySlugProvider } from '../../router'
import { prepareCommunityDraft, useStore } from '../../store'
import SetupPage from '../SetupPage'

const presets: ScoringPreset[] = [
  {
    id: 'single',
    label: 'One game',
    gamesToWin: 1,
    pointsToWin: 21,
    winBy: 2,
    maxPoints: 21,
    deuceAt: null,
    changeEndsAt: null,
  },
  {
    id: 'best-of-3',
    label: 'Best of 3',
    gamesToWin: 2,
    pointsToWin: 21,
    winBy: 2,
    maxPoints: 30,
    deuceAt: 20,
    changeEndsAt: null,
  },
]

function configStub(defaultPreset = 'best-of-3') {
  return mockFetch({
    'GET /api/c/acme/config': () => ({
      body: {
        scoringPresets: presets,
        effective: {
          'session.default_scoring_preset': { value: defaultPreset, source: 'community' },
        },
      },
    }),
  })
}

function LocationProbe() {
  return <span data-testid="pathname">{useLocation().pathname}</span>
}

function renderSetup() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={['/c/acme/session/new']}>
        <LegacySlugProvider slug="acme">
          <Routes>
            <Route path="/c/acme/session/new" element={<SetupPage />} />
            <Route path="*" element={<LocationProbe />} />
          </Routes>
        </LegacySlugProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

function startButton() {
  return screen.getByRole('button', { name: 'Start Session →' })
}

describe('SetupPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme')
    prepareCommunityDraft('acme')
    // The draft is a singleton: reset it so one case cannot seed the next.
    useStore.getState().resetSession()
  })

  it('refuses to start while the roster is below four players per court and names the shortfall', () => {
    configStub()
    act(() => useStore.getState().setTitle('Sunday social'))

    renderSetup()

    expect(startButton()).toBeEnabled()

    for (let i = 0; i < 4; i += 1) {
      fireEvent.click(screen.getByRole('button', { name: 'Decrease players' }))
    }

    expect(screen.getByText(/Need at least 8 players for 2 courts/)).toBeInTheDocument()
    expect(startButton()).toBeDisabled()

    // A disabled button must not lock the draft or leave the setup step.
    fireEvent.click(startButton())
    expect(useStore.getState().session.locked).toBe(false)
    expect(screen.queryByTestId('pathname')).not.toBeInTheDocument()

    // One court needs four players, and the roster now has four.
    fireEvent.click(screen.getByRole('button', { name: 'Decrease courts' }))
    expect(screen.queryByText(/Need at least/)).not.toBeInTheDocument()
    expect(startButton()).toBeEnabled()
  })

  it('refuses to start on an empty or over-long title, or with no date', () => {
    configStub()
    act(() => useStore.getState().setTitle('x'.repeat(120)))

    renderSetup()

    expect(startButton()).toBeEnabled()

    // The input stops at 120 characters, so an over-long title can only arrive
    // in the draft (a restored blob has no input bound); it is still refused.
    act(() => useStore.getState().setTitle('x'.repeat(121)))
    expect(startButton()).toBeDisabled()

    act(() => useStore.getState().setTitle(''))
    expect(startButton()).toBeDisabled()
    expect(screen.getByText('Session title and date are required to start.')).toBeInTheDocument()

    act(() => useStore.getState().setTitle('Sunday social'))
    act(() => useStore.getState().setDate(''))
    expect(startButton()).toBeDisabled()
    expect(screen.getByText('Session title and date are required to start.')).toBeInTheDocument()
  })

  it('locks the draft and moves on to the players step when the setup is valid', () => {
    configStub()
    act(() => useStore.getState().setTitle('Sunday social'))

    renderSetup()

    fireEvent.click(startButton())

    expect(useStore.getState().session.locked).toBe(true)
    expect(screen.getByTestId('pathname')).toHaveTextContent('/c/acme/session/players')
  })

  it('offers the community formats and preselects the community default', async () => {
    configStub('best-of-3')

    renderSetup()

    expect(await screen.findByText('One game')).toBeInTheDocument()
    expect(screen.getByText('Best of 3 · first to 21 · deuce 20 · cap 30')).toBeInTheDocument()
    expect(screen.getByText('One game to 21')).toBeInTheDocument()

    const radios = screen.getAllByRole('radio')
    expect(radios).toHaveLength(2)
    expect(radios[0]).not.toBeChecked()
    expect(radios[1]).toBeChecked()
  })
})