import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useOnline, useServiceWorkerControlled } from './useConnectivity'

function setOnline(value: boolean) {
  Object.defineProperty(navigator, 'onLine', { value, configurable: true })
}

interface FakeContainer {
  controller: object | null
  addEventListener: ReturnType<typeof vi.fn>
  removeEventListener: ReturnType<typeof vi.fn>
}

function setServiceWorker(controller: object | null) {
  const listeners = new Map<string, () => void>()
  const container: FakeContainer = {
    controller,
    addEventListener: vi.fn((type: string, handler: () => void) => {
      listeners.set(type, handler)
    }),
    removeEventListener: vi.fn(),
  }
  Object.defineProperty(navigator, 'serviceWorker', {
    value: container,
    configurable: true,
  })
  return {
    container,
    setController: (next: object | null) => {
      container.controller = next
    },
    dispatch: (type: string) => listeners.get(type)?.(),
  }
}

afterEach(() => {
  Reflect.deleteProperty(navigator, 'onLine')
  Reflect.deleteProperty(navigator, 'serviceWorker')
})

describe('useOnline', () => {
  it('reports the current navigator.onLine value', () => {
    setOnline(false)
    const { result } = renderHook(() => useOnline())
    expect(result.current).toBe(false)
  })

  it('follows the offline and online events', () => {
    setOnline(true)
    const { result } = renderHook(() => useOnline())

    setOnline(false)
    act(() => {
      window.dispatchEvent(new Event('offline'))
    })
    expect(result.current).toBe(false)

    setOnline(true)
    act(() => {
      window.dispatchEvent(new Event('online'))
    })
    expect(result.current).toBe(true)
  })

  it('removes both listeners on unmount', () => {
    const remove = vi.spyOn(window, 'removeEventListener')
    const { unmount } = renderHook(() => useOnline())

    unmount()

    expect(remove).toHaveBeenCalledWith('online', expect.any(Function))
    expect(remove).toHaveBeenCalledWith('offline', expect.any(Function))
    remove.mockRestore()
  })
})

describe('useServiceWorkerControlled', () => {
  it('is false without service worker support', () => {
    const { result } = renderHook(() => useServiceWorkerControlled())
    expect(result.current).toBe(false)
  })

  it('is false while nothing controls the page', () => {
    setServiceWorker(null)
    const { result } = renderHook(() => useServiceWorkerControlled())
    expect(result.current).toBe(false)
  })

  it('becomes true on controllerchange and back on a later change', () => {
    const sw = setServiceWorker(null)
    const { result } = renderHook(() => useServiceWorkerControlled())
    expect(result.current).toBe(false)

    act(() => {
      sw.setController({})
      sw.dispatch('controllerchange')
    })
    expect(result.current).toBe(true)

    act(() => {
      sw.setController(null)
      sw.dispatch('controllerchange')
    })
    expect(result.current).toBe(false)
  })

  it('unsubscribes from controllerchange on unmount', () => {
    const sw = setServiceWorker({})
    const { result, unmount } = renderHook(() => useServiceWorkerControlled())
    expect(result.current).toBe(true)

    unmount()

    expect(sw.container.removeEventListener).toHaveBeenCalledWith(
      'controllerchange',
      expect.any(Function),
    )
  })
})
