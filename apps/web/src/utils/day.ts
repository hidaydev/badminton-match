/**
 * The API sends a timestamp; most screens only need its calendar day, and the
 * full value carries microseconds that no baseline can pin.
 */
export function formatDay(value: string): string {
  return /^\d{4}-\d{2}-\d{2}/.test(value) ? value.slice(0, 10) : value
}
