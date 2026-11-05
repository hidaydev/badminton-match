/** A short client-side id for draft players and constraints. */
export function generateId(): string {
  const uuid = typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : Math.random().toString(36).slice(2) + Date.now().toString(36)
  return uuid.replace(/-/g, '').slice(0, 9)
}
