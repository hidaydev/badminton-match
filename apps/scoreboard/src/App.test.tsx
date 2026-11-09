import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { act } from 'react'
import App from './App'

const updateMock = vi.hoisted(() => ({
  needRefresh: false,
  applyUpdate: vi.fn(),
  dismiss: vi.fn(),
}))

vi.mock('./hooks/useAppUpdate', () => ({
  useAppUpdate: () => ({
    needRefresh: updateMock.needRefresh,
    applyUpdate: updateMock.applyUpdate,
    dismiss: updateMock.dismiss,
  }),
}))

const iphoneAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) Safari/605.1'

function setUserAgent(agent: string) {
  vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(agent)
}

const today = () => new Date().toDateString()

beforeEach(() => {
  updateMock.needRefresh = false
  updateMock.applyUpdate.mockClear()
  updateMock.dismiss.mockClear()
})

describe('App', () => {
  it('renders the scoreboard underneath everything else', () => {
    render(<App />)
    expect(screen.getByRole('main')).toBeInTheDocument()
    expect(screen.getByText('RED')).toBeInTheDocument()
    expect(screen.getByText('BLUE')).toBeInTheDocument()
  })

  it('offers the install sheet once per day on an iOS browser', () => {
    setUserAgent(iphoneAgent)
    render(<App />)

    expect(screen.getByRole('dialog', { name: 'Install app' })).toBeInTheDocument()
  })

  it('records the day when the sheet is dismissed and does not return', async () => {
    setUserAgent(iphoneAgent)
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: 'Got it' }))

    expect(localStorage.getItem('pwa-install-shown')).toBe(today())
    await act(async () => {})
    expect(screen.queryByRole('dialog', { name: 'Install app' })).not.toBeInTheDocument()
  })

  it('stays closed when the sheet was already shown today', () => {
    setUserAgent(iphoneAgent)
    localStorage.setItem('pwa-install-shown', today())
    render(<App />)

    expect(screen.queryByRole('dialog', { name: 'Install app' })).not.toBeInTheDocument()
  })

  it('installs from the sheet, records the day and closes', async () => {
    setUserAgent('Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0')
    const prompt = vi.fn(async () => {})
    const event = new Event('beforeinstallprompt') as Event & {
      prompt: () => Promise<void>
      userChoice: Promise<{ outcome: string }>
    }
    event.prompt = prompt
    event.userChoice = Promise.resolve({ outcome: 'accepted' })

    render(<App />)
    act(() => {
      window.dispatchEvent(event)
    })

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Install App' }))
    })

    expect(prompt).toHaveBeenCalledTimes(1)
    expect(localStorage.getItem('pwa-install-shown')).toBe(today())
    expect(screen.queryByRole('dialog', { name: 'Install app' })).not.toBeInTheDocument()
  })

  it('does not offer installation on a desktop browser with no install event', () => {
    setUserAgent('Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0')
    render(<App />)

    expect(screen.queryByRole('dialog', { name: 'Install app' })).not.toBeInTheDocument()
  })

  it('shows the update prompt when a worker is waiting', () => {
    setUserAgent('Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0')
    updateMock.needRefresh = true

    render(<App />)

    expect(screen.getByRole('status')).toHaveTextContent('A new version is available')
  })

  it('activates the waiting worker from the prompt', async () => {
    setUserAgent('Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0')
    updateMock.needRefresh = true
    render(<App />)

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Reload' }))
    })

    expect(updateMock.applyUpdate).toHaveBeenCalledTimes(1)
  })
})