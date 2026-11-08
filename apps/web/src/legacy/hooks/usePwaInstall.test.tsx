import { describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { usePwaInstall } from './usePwaInstall'

const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15'

function displayMode(isStandalone: boolean) {
  vi.spyOn(window, 'matchMedia').mockImplementation(
    (query: string) =>
      ({
        matches: isStandalone && query.includes('standalone'),
        media: query,
        onchange: null,
        addListener: () => {},
        removeListener: () => {},
        addEventListener: () => {},
        removeEventListener: () => {},
        dispatchEvent: () => false,
      }) as MediaQueryList,
  )
}

function installPrompt(outcome: 'accepted' | 'dismissed') {
  const prompt = vi.fn(async () => {})
  const event: Event = Object.assign(new Event('beforeinstallprompt'), {
    prompt,
    userChoice: Promise.resolve({ outcome }),
  })
  return { event, prompt }
}

describe('usePwaInstall', () => {
  it('is not installable in standalone mode even on iOS', () => {
    vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(IPHONE)
    displayMode(true)

    const { result } = renderHook(() => usePwaInstall())

    // The iOS branch really is live here, so the false result is the
    // standalone gate and not a failed platform check.
    expect(result.current.isIos).toBe(true)
    expect(result.current.isInstallable).toBe(false)
  })

  it('does nothing when no install prompt was captured', async () => {
    const { result } = renderHook(() => usePwaInstall())

    expect(result.current.isInstallable).toBe(false)
    await expect(result.current.prompt()).resolves.toBeUndefined()
    expect(result.current.isInstallable).toBe(false)
  })

  it('holds the deferred prompt until the user accepts', async () => {
    const dismissed = installPrompt('dismissed')
    const { result } = renderHook(() => usePwaInstall())

    act(() => {
      window.dispatchEvent(dismissed.event)
    })
    expect(result.current.isInstallable).toBe(true)

    await act(async () => {
      await result.current.prompt()
    })
    expect(dismissed.prompt).toHaveBeenCalledTimes(1)
    expect(result.current.isInstallable).toBe(true)

    const accepted = installPrompt('accepted')
    act(() => {
      window.dispatchEvent(accepted.event)
    })

    await act(async () => {
      await result.current.prompt()
    })
    expect(accepted.prompt).toHaveBeenCalledTimes(1)
    expect(result.current.isInstallable).toBe(false)
  })

  it('is installable on iOS without a prompt event', () => {
    vi.spyOn(window.navigator, 'userAgent', 'get').mockReturnValue(IPHONE)
    displayMode(false)

    const { result } = renderHook(() => usePwaInstall())

    expect(result.current.isInstallable).toBe(true)
  })
})