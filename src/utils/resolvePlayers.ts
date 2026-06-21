import type { Player } from '../store'
import type { PlayerSummary } from '../queries'

export function isKnownPlayer(name: string, knownPlayers: PlayerSummary[]): boolean {
  const normalized = name.trim().toLowerCase().replace(/\s+/g, ' ')
  return knownPlayers.some((kp) => {
    const kn = kp.name.trim().toLowerCase().replace(/\s+/g, ' ')
    return kn === normalized
  })
}

export function findUnresolvedPlayers(localPlayers: Player[], knownPlayers: PlayerSummary[]): Player[] {
  return localPlayers.filter((p) => !isKnownPlayer(p.name, knownPlayers))
}

export interface ResolveEntry {
  player: Player
  mode: 'new' | 'merge'
  mergeTarget: string | null
}

export interface ResolveResult {
  registerNew: { name: string }[]
  registerAlias: { alias: string; canonical: string }[]
  renameMap: Map<string, string>
}

export function buildResolveResult(
  unresolved: Player[],
  entries: Record<string, ResolveEntry>,
): ResolveResult {
  const registerNew: { name: string }[] = []
  const registerAlias: { alias: string; canonical: string }[] = []
  const renameMap = new Map<string, string>()

  for (const p of unresolved) {
    const entry = entries[p.id]
    if (!entry) continue
    if (entry.mode === 'new') {
      registerNew.push({ name: p.name })
    } else {
      const target = entry.mergeTarget
      if (!target) {
        registerNew.push({ name: p.name })
      } else {
        registerAlias.push({ alias: p.name, canonical: target })
        renameMap.set(p.id, target)
      }
    }
  }

  return { registerNew, registerAlias, renameMap }
}
