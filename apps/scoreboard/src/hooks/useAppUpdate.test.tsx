import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { useAppUpdate } from './useAppUpdate'

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

afterEach(() => {
  Reflect.deleteProperty(navigator, 'serviceWorker')
})

function Harness() {
  const { needRefresh, applyUpdate, dismiss } = useAppUpdate()
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
})
