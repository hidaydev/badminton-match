type Listener = () => void

const memory = new Map<string, string>()
const listeners = new Set<Listener>()
let unavailable = false

function markUnavailable() {
  if (unavailable) return
  unavailable = true
  for (const listener of listeners) listener()
}

export function readStoredValue(key: string): string | null {
  const cached = memory.get(key)
  if (cached !== undefined) return cached
  try {
    return window.localStorage.getItem(key)
  } catch {
    markUnavailable()
    return null
  }
}

export function writeStoredValue(key: string, value: string): void {
  memory.set(key, value)
  try {
    window.localStorage.setItem(key, value)
  } catch {
    markUnavailable()
  }
}

export function isStorageUnavailable(): boolean {
  return unavailable
}

export function subscribeStorageStatus(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

// Clears the fallback cache and the warning so a later render starts fresh.
// Used by tests and after site data is cleared.
export function resetStorageStatus(): void {
  memory.clear()
  unavailable = false
}
