/**
 * ADR-018: one production database serves one community until row level
 * security ships, and the API refuses to boot against a database that holds
 * two (`modules/community/tenancy.nim`).
 *
 * A production bundle is the bundle that reaches that deployment, so the
 * Setup screen refuses to create a second community unless a build says
 * otherwise. `VITE_SINGLE_COMMUNITY` overrides both ways:
 *
 *   unset               a production build is guarded, a dev server is not
 *   VITE_SINGLE_COMMUNITY=1  guarded, whatever the mode
 *   VITE_SINGLE_COMMUNITY=0  not guarded; the end-to-end harness needs this,
 *                            because it builds a production bundle against a
 *                            database that holds several communities on purpose
 *
 * A flag rather than a guess from the hostname or the API base: the guard is a
 * fact about the deployment, and a page cannot discover it from the browser.
 */
export function singleCommunityDeployment(): boolean {
  const flag = import.meta.env.VITE_SINGLE_COMMUNITY
  if (flag === '1') return true
  if (flag === '0') return false
  return import.meta.env.PROD
}
