import { afterEach, describe, expect, it, vi } from 'vitest'
import { installUpdateOnVisible, UPDATE_CHECK_INTERVAL_MS } from './updateCheck'

let now = 0
const clock = () => now

function setVisibility(value: DocumentVisibilityState) {
  Object.defineProperty(document, 'visibilityState', { value, configurable: true })
}

afterEach(() => {
  Reflect.deleteProperty(document, 'visibilityState')
})

describe('installUpdateOnVisible', () => {
  it('asks the registration for an update when the tab becomes visible', () => {
    const update = vi.fn(async () => {})
    setVisibility('visible')
    now = 0

    const stop = installUpdateOnVisible({ update }, { now: clock })
    now = UPDATE_CHECK_INTERVAL_MS * 2
    document.dispatchEvent(new Event('visibilitychange'))

    expect(update).toHaveBeenCalledTimes(1)
    stop()
  })

  it('does not check while hidden', () => {
    const update = vi.fn(async () => {})
    setVisibility('hidden')
    now = 0

    const stop = installUpdateOnVisible({ update }, { now: clock })
    now = UPDATE_CHECK_INTERVAL_MS * 2
    document.dispatchEvent(new Event('visibilitychange'))

    expect(update).not.toHaveBeenCalled()
    stop()
  })

  it('throttles checks to one per interval', () => {
    const update = vi.fn(async () => {})
    setVisibility('visible')
    now = 0

    const stop = installUpdateOnVisible({ update }, { now: clock })
    now = UPDATE_CHECK_INTERVAL_MS
    document.dispatchEvent(new Event('visibilitychange'))
    now += UPDATE_CHECK_INTERVAL_MS / 2
    document.dispatchEvent(new Event('visibilitychange'))
    expect(update).toHaveBeenCalledTimes(1)

    now += UPDATE_CHECK_INTERVAL_MS
    document.dispatchEvent(new Event('visibilitychange'))
    expect(update).toHaveBeenCalledTimes(2)
    stop()
  })

  it('stops listening when cleaned up', () => {
    const update = vi.fn(async () => {})
    setVisibility('visible')
    now = 0

    const stop = installUpdateOnVisible({ update }, { now: clock })
    now = UPDATE_CHECK_INTERVAL_MS * 2
    stop()
    document.dispatchEvent(new Event('visibilitychange'))

    expect(update).not.toHaveBeenCalled()
  })

  // REL-FE-10: the plugin raises its prompt once per waiting worker, so a
  // dismissed banner never came back and the tablet kept the old precache.
  it('re-raises the prompt when a check finds a worker still waiting', async () => {
    setVisibility('visible')
    now = 0
    const onWaiting = vi.fn()
    const registration = {
      update: vi.fn(async () => {}),
      waiting: { scriptURL: '/sw.js' },
    }

    const stop = installUpdateOnVisible(registration, { now: clock, onWaiting })
    now = UPDATE_CHECK_INTERVAL_MS * 2
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.waitFor(() => expect(onWaiting).toHaveBeenCalledTimes(1))

    // The next check, after the admin dismisses again, raises it again.
    now += UPDATE_CHECK_INTERVAL_MS
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.waitFor(() => expect(onWaiting).toHaveBeenCalledTimes(2))
    stop()
  })

  it('leaves the banner alone when no worker is waiting', async () => {
    setVisibility('visible')
    now = 0
    const onWaiting = vi.fn()
    const registration = { update: vi.fn(async () => {}), waiting: null }

    const stop = installUpdateOnVisible(registration, { now: clock, onWaiting })
    now = UPDATE_CHECK_INTERVAL_MS * 2
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.waitFor(() => expect(registration.update).toHaveBeenCalledTimes(1))

    expect(onWaiting).not.toHaveBeenCalled()
    stop()
  })
})
