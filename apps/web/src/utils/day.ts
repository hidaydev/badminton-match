/** The community default from the seed; a community may set another zone. */
export const DEFAULT_TIME_ZONE = 'Asia/Jakarta'

let activeTimeZone = DEFAULT_TIME_ZONE

/**
 * Publishes the effective `community.default_timezone` to the screens that
 * compute "today" before they have read the config (the session draft, the
 * tournament wizard, the poster). An unset or blank value keeps the default.
 */
export function setActiveTimeZone(timeZone: string | null | undefined): void {
  const trimmed = typeof timeZone === 'string' ? timeZone.trim() : ''
  activeTimeZone = trimmed === '' ? DEFAULT_TIME_ZONE : trimmed
}

export function activeTimeZoneId(): string {
  return activeTimeZone
}

/**
 * The API sends a timestamp; most screens only need its calendar day, and the
 * full value carries microseconds that no baseline can pin.
 *
 * This slices, so it is for calendar dates (`session.date`, `YYYY-MM-DD`) only.
 * A full instant must go through `formatInstantDate`: slicing an instant takes
 * the UTC day, which is one day behind Jakarta for anything recorded between
 * midnight and 07:00 WIB.
 */
export function formatDay(value: string): string {
  return /^\d{4}-\d{2}-\d{2}/.test(value) ? value.slice(0, 10) : value
}

/**
 * The API writes `2026-11-01 10:00:00+07` (space, short offset) and also ISO
 * with a `T` and a full offset; both are the same instant. `Date` only parses
 * the second shape reliably.
 */
function parseInstant(value: string): Date | null {
  const normalized = value.trim().replace(' ', 'T').replace(/([+-]\d{2})$/, '$1:00')
  const parsed = new Date(normalized)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

/**
 * A full instant as the community reads it: `4 Nov 2026` in the community's
 * timezone, not the UTC day the string happens to start with. A value that is
 * not a timestamp comes back unchanged, so a screen never shows "Invalid date".
 */
export function formatInstantDate(value: string, timeZone: string = DEFAULT_TIME_ZONE): string {
  const parsed = parseInstant(value)
  if (parsed === null) return value
  return new Intl.DateTimeFormat('en-GB', {
    timeZone,
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(parsed)
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
