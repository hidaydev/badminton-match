import { useEffect } from 'react'
import type { DependencyList } from 'react'

/**
 * The one cancellation guard for an async effect. Every fetch effect used to
 * declare its own boolean and flip it in its cleanup, so a late answer could
 * still land after the component left. The hook owns the flag and the
 * teardown list instead: the caller reads `scope.live` inside its promise
 * callbacks and registers timers or listeners with `scope.onCleanup`.
 */
export type AsyncEffectScope = {
  /** False from the moment the effect is cleaned up. */
  readonly live: boolean
  /** Run this when the effect is cleaned up, in registration order. */
  onCleanup: (teardown: () => void) => void
}

export function useAsyncEffect(
  effect: (scope: AsyncEffectScope) => void,
  deps: DependencyList,
): void {
  useEffect(() => {
    let cancelled = false
    const teardowns: (() => void)[] = []
    const scope: AsyncEffectScope = {
      get live() {
        return !cancelled
      },
      onCleanup: (teardown) => {
        teardowns.push(teardown)
      },
    }

    effect(scope)

    return () => {
      cancelled = true
      for (const teardown of teardowns) teardown()
    }
    // The caller owns the dependency list, exactly as it did with useEffect;
    // the effect closure is the one bound to that list.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
}
