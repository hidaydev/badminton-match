/**
 * Full-page redirect to the OIDC authorize URL. Isolated so tests can replace
 * it: jsdom's `location.assign` cannot be spied on.
 */
export function redirectTo(url: string): void {
  window.location.assign(url)
}
