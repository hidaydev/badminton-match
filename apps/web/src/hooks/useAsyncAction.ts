import { useCallback, useState } from 'react'

export interface AsyncAction<Args extends unknown[]> {
  busy: boolean
  error: string | null
  /** Runs the action. Resolves true on success, false when it threw. */
  run: (...args: Args) => Promise<boolean>
  reset: () => void
}

export interface AsyncActionOptions {
  /** Turns a thrown value into the sentence shown next to the form. */
  describeError?: (problem: unknown) => string
  /** Runs after a successful action, before `busy` clears. */
  onSuccess?: () => void
  /** Receives the same sentence as `error`, for a form that owns the status line. */
  onError?: (message: string) => void
}

function defaultDescribe(problem: unknown): string {
  return problem instanceof Error ? problem.message : String(problem)
}

/**
 * The one busy/error wrapper for a mutation. Every handler used to declare its
 * own flag, clear its own error and write its own try/catch/finally; this owns
 * the flag so a rejected action always leaves the form interactive again.
 */
export function useAsyncAction<Args extends unknown[] = []>(
  action: (...args: Args) => Promise<unknown>,
  options: AsyncActionOptions = {},
): AsyncAction<Args> {
  const { describeError = defaultDescribe, onSuccess, onError } = options
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const run = useCallback(
    async (...args: Args): Promise<boolean> => {
      setBusy(true)
      setError(null)
      try {
        await action(...args)
        onSuccess?.()
        return true
      } catch (problem) {
        const message = describeError(problem)
        setError(message)
        onError?.(message)
        return false
      } finally {
        setBusy(false)
      }
    },
    [action, describeError, onSuccess, onError],
  )

  const reset = useCallback(() => setError(null), [])

  return { busy, error, run, reset }
}
