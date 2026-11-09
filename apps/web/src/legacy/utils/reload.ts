/**
 * Full page reload behind one function, so callers that need the server's
 * current state (a stale conditional write, a new bundle) do not touch
 * `window.location` directly and a test can observe the reload.
 */
export function reloadPage(): void {
  window.location.reload()
}
