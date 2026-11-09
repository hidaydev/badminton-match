import { routes } from './api'
import type { RouteSpec } from './api'

function escapeSegment(segment: string): string {
  return segment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * A route table path as a matcher: `{slug}` and any other path parameter match
 * one segment. Trailing slashes are ignored on both sides.
 */
export function routePattern(path: string): RegExp {
  const segments = path.replace(/\/$/, '').split('/')
  const pattern = segments
    .map(segment => (/^\{[^}]+\}$/.test(segment) ? '[^/]+' : escapeSegment(segment)))
    .join('/')
  return new RegExp(`^${pattern}$`)
}

/**
 * True when a call site's path literal names a route the contract declares.
 * Template placeholders (`${...}`) are treated as path parameters.
 */
export function matchesRoute(path: string, table: readonly RouteSpec[] = routes): boolean {
  const candidate = path.replace(/\$\{[^}]*\}/g, 'x').replace(/\/$/, '')
  return table.some(route => routePattern(route.path).test(candidate))
}
