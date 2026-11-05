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

/**
 * The same day in the width a phone has: `Tue, 3 Nov 2026`. Used where the date
 * shares a line with something else, so the long form would wrap or truncate.
 */
export function formatCompactDate(value: string): string {
  const parsed = new Date(`${formatDay(value)}T00:00:00`)
  if (Number.isNaN(parsed.getTime())) return value
  // Assembled from parts because en-US orders a short month before the day
  // ("Nov 3"); the requested shape is day first, which no locale gives us.
  const parts = new Intl.DateTimeFormat('en-US', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).formatToParts(parsed)
  const part = (type: Intl.DateTimeFormatPartTypes): string =>
    parts.find((entry) => entry.type === type)?.value ?? ''
  return `${part('weekday')}, ${part('day')} ${part('month')} ${part('year')}`
}
