/**
 * Consumes a promise nobody will await.
 *
 * Two shapes, one silence policy. Without a `where` the failure is already
 * reported somewhere else: a read through TanStack Query puts its failure in the
 * query's error state, so the rejected promise a caller would otherwise drop has
 * nothing left to say. With a `where` nothing else would report it, so one line
 * names the step that failed.
 */
export function settled(work: Promise<unknown>, where?: string): void {
  work.catch((error: unknown) => {
    if (where !== undefined) console.error(where, error)
  })
}
