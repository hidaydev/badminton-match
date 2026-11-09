import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { UPDATE_CHECK_INTERVAL_MS, useAppUpdate } from './useAppUpdate'

interface FakeWorker {
  state: string
  postMessage: ReturnType<typeof vi.fn>
  addEventListener: ReturnType<typeof vi.fn>
  fireStateChange: () => void
}

function fakeWorker(state = 'installing'): FakeWorker {
  const listeners: Array<() => void> = []
  return {
    state,
    postMessage: vi.fn(),
    addEventListener: vi.fn((_event: string, listener: () => void) => {
      listeners.push(listener)
    }),
    fireStateChange: () => {
      for (const listener of listeners) listener()
    },
  }
}

function fakeRegistration(overrides: Record<string, unknown> = {}) {
  const listeners = new Map<string, () => void>()
  return {
    waiting: null as unknown,
    installing: null as unknown,
    update: vi.fn(async () => undefined),
    addEventListener: vi.fn((event: string, listener: () => void) => {
      listeners.set(event, listener)
    }),
    removeEventListener: vi.fn(),
    fire: (event: string) => listeners.get(event)?.(),
    ...overrides,
  }
}

function installServiceWorker(container: Record<string, unknown>) {
  Object.defineProperty(navigator, 'serviceWorker', {
    value: container,
    configurable: true,
  })
}

function installContainer(registration: unknown, controller: unknown = {}) {
  const listeners = new Map<string, () => void>()
  const container = {
    controller,
    ready: Promise.resolve(registration),
    addEventListener: vi.fn((event: string, listener: () => void) => {
      listeners.set(event, listener)
    }),
    removeEventListener: vi.fn(),
    fire: (event: string) => listeners.get(event)?.(),
  }
  installServiceWorker(container)
  return container
}

afterEach(() => {
  vi.useRealTimers()
  Reflect.deleteProperty(navigator, 'serviceWorker')
})

function Harness({ reload }: { reload?: () => void } = {}) {
  const { needRefresh, applyUpdate, dismiss } = useAppUpdate({ reload })
  return (
    <div>
      <span>{needRefresh ? 'refresh' : 'idle'}</span>
      <button type="button" onClick={applyUpdate}>apply</button>
      <button type="button" onClick={dismiss}>dismiss</button>
    </div>
  )
}

describe('useAppUpdate', () => {
  it('stays idle when the browser has no service worker', () => {
    render(<Harness />)

    expect(screen.getByText('idle')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'apply' }))
    expect(screen.getByText('idle')).toBeInTheDocument()
  })

  it('stays idle when no worker is waiting', async () => {
    const registration = fakeRegistration()
    installServiceWorker({ controller: {}, ready: Promise.resolve(registration), addEventListener: vi.fn(), removeEventListener: vi.fn() })

    await act(async () => {
      render(<Harness />)
    })

    expect(screen.getByText('idle')).toBeInTheDocument()
  })

  it('surfaces a waiting worker and activates it with SKIP_WAITING', async () => {
    const worker = fakeWorker('installed')
    const registration = fakeRegistration({ waiting: worker })
    installServiceWorker({
      controller: {},
      ready: Promise.resolve(registration),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })

    await act(async () => {
      render(<Harness />)
    })
    expect(screen.getByText('refresh')).toBeInTheDocument()

    act(() => {
      fireEvent.click(screen.getByRole('button', { name: 'apply' }))
    })

    expect(worker.postMessage).toHaveBeenCalledWith({ type: 'SKIP_WAITING' })
    expect(screen.getByText('idle')).toBeInTheDocument()
  })

  it('surfaces a worker that installs while the page is open', async () => {
    const worker = fakeWorker()
    const registration = fakeRegistration()
    installServiceWorker({
      controller: {},
      ready: Promise.resolve(registration),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })

    await act(async () => {
      render(<Harness />)
    })
    expect(screen.getByText('idle')).toBeInTheDocument()

    registration.installing = worker
    act(() => registration.fire('updatefound'))
    worker.state = 'installed'
    act(() => worker.fireStateChange())

    expect(screen.getByText('refresh')).toBeInTheDocument()
  })

  it('polls the registration so a board open all day learns about a deploy', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] })
    const registration = fakeRegistration()
    installContainer(registration)

    await act(async () => {
      render(<Harness />)
    })
    expect(registration.update).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(UPDATE_CHECK_INTERVAL_MS)
    })
    expect(registration.update).toHaveBeenCalledTimes(1)

    act(() => {
      vi.advanceTimersByTime(UPDATE_CHECK_INTERVAL_MS)
    })
    expect(registration.update).toHaveBeenCalledTimes(2)
  })

  it('stops polling when the board unmounts', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] })
    const registration = fakeRegistration()
    installContainer(registration)

    const { unmount } = render(<Harness />)
    await act(async () => {})
    unmount()

    act(() => {
      vi.advanceTimersByTime(UPDATE_CHECK_INTERVAL_MS * 2)
    })
    expect(registration.update).not.toHaveBeenCalled()
  })

  it('hides the prompt after a dismissal', async () => {
    const worker = fakeWorker('installed')
    const registration = fakeRegistration({ waiting: worker })
    installServiceWorker({
      controller: {},
      ready: Promise.resolve(registration),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })

    await act(async () => {
      render(<Harness />)
    })
    fireEvent.click(screen.getByRole('button', { name: 'dismiss' }))

    expect(screen.getByText('idle')).toBeInTheDocument()
    expect(worker.postMessage).not.toHaveBeenCalled()
  })

  it('reloads once when the new worker takes control after an update', async () => {
    const worker = fakeWorker('installed')
    const registration = fakeRegistration({ waiting: worker })
    const container = installContainer(registration)
    const reload = vi.fn()

    await act(async () => {
      render(<Harness reload={reload} />)
    })
    act(() => {
      fireEvent.click(screen.getByRole('button', { name: 'apply' }))
    })
    act(() => {
      container.fire('controllerchange')
    })

    expect(reload).toHaveBeenCalledTimes(1)
  })

  it('does not reload when no update is pending', async () => {
    const registration = fakeRegistration({ waiting: fakeWorker('installed') })
    const container = installContainer(registration)
    const reload = vi.fn()

    await act(async () => {
      render(<Harness reload={reload} />)
    })
    act(() => {
      container.fire('controllerchange')
    })

    expect(reload).not.toHaveBeenCalled()
  })
})
