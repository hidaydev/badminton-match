/** The last session this browser opened, so Home can offer a one-tap return. */
export type LastSession = {
  id: string
  title: string
  date: string
}

function key(slug: string): string {
  return `majadu.lastSession.${slug}`
}

export function readLastSession(slug: string): LastSession | null {
  try {
    const raw = window.localStorage.getItem(key(slug))
    if (raw === null) return null
    const parsed = JSON.parse(raw) as Partial<LastSession>
    if (typeof parsed.id !== 'string' || typeof parsed.title !== 'string' || typeof parsed.date !== 'string') {
      return null
    }
    return { id: parsed.id, title: parsed.title, date: parsed.date }
  } catch {
    return null
  }
}

export function writeLastSession(slug: string, session: LastSession): void {
  try {
    window.localStorage.setItem(key(slug), JSON.stringify(session))
  } catch {
    // Storage can be unavailable; the card simply does not appear.
  }
}
