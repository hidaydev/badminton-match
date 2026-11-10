import { act, renderHook, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../queries/endpoints'
import { useScoreDraft } from './useScoreDraft'

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('useScoreDraft retry guard', () => {
  it('sends one PATCH while the first retry is still open', async () => {
    const retry = deferred<void>()
    const onSetGameScore = vi
      .fn()
      .mockRejectedValueOnce(new ApiError('offline', null, null))
      .mockImplementationOnce(() => retry.promise)

    const { result } = renderHook(() => useScoreDraft(onSetGameScore))

    act(() => result.current.setDraftScores({ '0-0': [{ a: '21', b: '15' }] }))
    act(() => result.current.handleScoreSave('0-0'))
    await waitFor(() =>
      expect(result.current.scoreFailures['0-0'].message).toBe('That change was not saved.'),
    )

    act(() => {
      result.current.retryScore('0-0')
      result.current.retryScore('0-0')
    })

    expect(onSetGameScore).toHaveBeenCalledTimes(2)

    act(() => retry.resolve())
    await waitFor(() => expect(result.current.scoreFailures['0-0']).toBeUndefined())
  })
})
