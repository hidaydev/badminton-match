import { describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useAsyncAction } from './useAsyncAction'

describe('useAsyncAction', () => {
  it('runs the action, reports success and clears busy', async () => {
    const action = vi.fn(async () => undefined)
    const { result } = renderHook(() => useAsyncAction(action))

    let outcome: boolean | undefined
    await act(async () => {
      outcome = await result.current.run()
    })

    expect(outcome).toBe(true)
    expect(action).toHaveBeenCalledTimes(1)
    expect(result.current.busy).toBe(false)
    expect(result.current.error).toBeNull()
  })

  it('leaves busy false and surfaces the message when the action rejects', async () => {
    const action = vi.fn(async () => {
      throw new Error('The server said no')
    })
    const { result } = renderHook(() => useAsyncAction(action))

    let outcome: boolean | undefined
    await act(async () => {
      outcome = await result.current.run()
    })

    expect(outcome).toBe(false)
    expect(result.current.busy).toBe(false)
    expect(result.current.error).toBe('The server said no')
  })

  it('uses the caller mapping for the error sentence', async () => {
    const action = vi.fn(async () => {
      throw new Error('raw')
    })
    const describeError = vi.fn(() => 'Friendly sentence')
    const { result } = renderHook(() => useAsyncAction(action, { describeError }))

    await act(async () => {
      await result.current.run()
    })

    expect(describeError).toHaveBeenCalled()
    expect(result.current.error).toBe('Friendly sentence')
  })

  it('passes arguments through and calls onSuccess only on success', async () => {
    const action = vi.fn(async (value: number) => {
      void value
    })
    const onSuccess = vi.fn()
    const { result } = renderHook(() => useAsyncAction(action, { onSuccess }))

    await act(async () => {
      await result.current.run(7)
    })

    expect(action).toHaveBeenCalledWith(7)
    expect(onSuccess).toHaveBeenCalledTimes(1)
  })

  it('clears the error without running anything', async () => {
    const action = vi.fn(async () => {
      throw new Error('no')
    })
    const { result } = renderHook(() => useAsyncAction(action))

    await act(async () => {
      await result.current.run()
    })
    act(() => result.current.reset())

    expect(result.current.error).toBeNull()
    expect(action).toHaveBeenCalledTimes(1)
  })
})
