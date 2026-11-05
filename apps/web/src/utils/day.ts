/**
 * The API sends a timestamp; most screens only need its calendar day, and the
 * full value carries microseconds that no baseline can pin.
 */
export function formatDay(value: string): string {
  return /^\d{4}-\d{2}-\d{2}/.test(value) ? value.slice(0, 10) : value
}

/**
 * A calendar day rendered with words ("Tuesday, 3 November 2026"). The locale is
 * fixed because the interface is English only; when a second language arrives,
 * this function is the one place that changes, not every screen.
 */
export function formatLongDate(value: string, weekday = true): string {
  const parsed = new Date(`${formatDay(value)}T00:00:00`)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleDateString('en-US', {
    ...(weekday ? { weekday: 'long' as const } : {}),
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
}
