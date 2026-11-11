import { describe, expect, it, vi } from 'vitest'

import { settled } from './settled'

describe('settled', () => {
  it('takes a rejection that is already reported instead of rethrowing it', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined)

    expect(() => settled(Promise.reject(new Error('already in the query state')))).not.toThrow()

    // The rejection has to be consumed by the time the microtask queue drains,
    // or the runner fails the case on an unhandled rejection.
    await Promise.resolve()
    await Promise.resolve()
    expect(consoleError).not.toHaveBeenCalled()
  })

  it('names the step when nothing else would report the failure', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const problem = new Error('boom')

    settled(Promise.reject(problem), 'share read failed')
    await Promise.resolve()
    await Promise.resolve()

    expect(consoleError).toHaveBeenCalledWith('share read failed', problem)
  })

  it('leaves a resolved promise alone', async () => {
    expect(() => settled(Promise.resolve('ok'))).not.toThrow()
    await Promise.resolve()
  })
})
