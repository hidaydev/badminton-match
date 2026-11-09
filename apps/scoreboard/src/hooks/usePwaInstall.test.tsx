import { describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { usePwaInstall } from '@majadu/scoreboard-ui'

const desktopAgent = 'Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0'
const iphoneAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) Safari/605.1'

function setUserAgent(agent: string) {
  vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(agent)
}

function setStandalone(matches: boolean) {
  vi.spyOn(window, 'matchMedia').mockImplementation((query: string) => ({
    matches,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }) as MediaQueryList)
}

/** The browser event is not constructible in jsdom; a plain Event carries the two methods. */
function installPromptEvent(outcome: 'accepted' | 'dismissed') {
  const event = new Event('beforeinstallprompt') as Event & {
    prompt: () => Promise<void>
    userChoice: Promise<{ outcome: string }>
  }
  event.prompt = vi.fn(async () => {})
  event.userChoice = Promise.resolve({ outcome })
  return event
}

describe('usePwaInstall', () => {
  it('reports not installable in standalone mode, even on iOS', () => {
    setUserAgent(iphoneAgent)
    setStandalone(true)

    const { result } = renderHook(() => usePwaInstall())

    expect(result.current.isIos).toBe(true)
    expect(result.current.isInstallable).toBe(false)
  })

  it('treats an iOS browser without a prompt event as installable', () => {
    setUserAgent(iphoneAgent)
    setStandalone(false)

    const { result } = renderHook(() => usePwaInstall())

    expect(result.current.isIos).toBe(true)
    expect(result.current.isInstallable).toBe(true)
  })

  it('needs the deferred event on a desktop browser', () => {
    setUserAgent(desktopAgent)
    setStandalone(false)

    const { result } = renderHook(() => usePwaInstall())
    expect(result.current.isIos).toBe(false)
    expect(result.current.isInstallable).toBe(false)

    act(() => {
      window.dispatchEvent(installPromptEvent('accepted'))
    })
    expect(result.current.isInstallable).toBe(true)
  })

  it('does nothing when prompt is called with no captured event', async () => {
    setUserAgent(desktopAgent)
    setStandalone(false)

    const { result } = renderHook(() => usePwaInstall())
    await act(async () => {
      await result.current.prompt()
    })

    expect(result.current.isInstallable).toBe(false)
  })

  it('clears the deferred prompt only when the user accepts', async () => {
    setUserAgent(desktopAgent)
    setStandalone(false)
    const accepted = installPromptEvent('accepted')

    const { result } = renderHook(() => usePwaInstall())
    act(() => {
      window.dispatchEvent(accepted)
    })

    await act(async () => {
      await result.current.prompt()
    })

    expect(accepted.prompt).toHaveBeenCalledTimes(1)
    expect(result.current.isInstallable).toBe(false)
  })

  it('keeps the deferred prompt when the user dismisses', async () => {
    setUserAgent(desktopAgent)
    setStandalone(false)
    const dismissed = installPromptEvent('dismissed')

    const { result } = renderHook(() => usePwaInstall())
    act(() => {
      window.dispatchEvent(dismissed)
    })

    await act(async () => {
      await result.current.prompt()
    })

    expect(result.current.isInstallable).toBe(true)
  })
})