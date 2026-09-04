import type { Player, MatchConstraint } from '../../types'
import { PLAYERS_PER_GAME } from '../../types'
import { useStore } from '../../store'
import { selectTotalGames } from '../../store/selectors'
import { timeToMinutes } from '../../utils/time'

export interface ValidationResult {
  hasErrors: boolean
  tooManyTotal: boolean
  effectiveSlotsNeeded: number
  overloadedPlayers: { player: Player; count: number; max: number }[]
  pinnedConflicts: Map<number, string[]>  // matchIndex -> conflict messages
  singlePlayerPairs: { match: MatchConstraint; side: 'A' | 'B' }[]
}

export function useValidation(players: Player[], matches: MatchConstraint[]): ValidationResult {
  const session = useStore((s) => s.session)
  const expectedPlays = players.length > 0
    ? Math.round((selectTotalGames(session) * PLAYERS_PER_GAME) / players.length)
    : 0

  const counts: Record<string, number> = {}
  for (const m of matches) {
    for (const id of m.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  // Pairable matches (A-side only) can be merged in pairs → each pair uses 1 slot
  const pairableCount = matches.filter(m => m.mode !== 'pinned' && !!(m.slots[0] && m.slots[1] && !m.slots[2] && !m.slots[3])).length
  const pinnedCount = matches.filter(m => m.mode === 'pinned').length
  const nonPairableCount = matches.filter(m => m.mode !== 'pinned').length - pairableCount
  const effectiveSlotsNeeded = Math.ceil(pairableCount / 2) + nonPairableCount + pinnedCount
  const tooManyTotal = effectiveSlotsNeeded > selectTotalGames(session)
  const overloadedPlayers = players
    .map((p) => ({ player: p, count: counts[p.id] ?? 0, max: expectedPlays }))
    .filter(({ count, max }) => count > max)

  // Pinned match conflict detection
  const pinnedConflicts = new Map<number, string[]>()
  const pinnedMatches = matches.filter(m => m.mode === 'pinned')

  for (let i = 0; i < pinnedMatches.length; i++) {
    const m = pinnedMatches[i]
    const mIdx = matches.indexOf(m)
    const conflicts: string[] = []

    if (!m.pinnedTime || m.pinnedCourt === undefined) {
      conflicts.push('Time and court must be set for pinned match')
      pinnedConflicts.set(mIdx, conflicts)
      continue
    }

    // Check time alignment with slot grid
    const sessionStartMin = timeToMinutes(session.sessionStart)
    const pinnedTimeMin = timeToMinutes(m.pinnedTime)
    const offsetFromStart = pinnedTimeMin - sessionStartMin
    if (offsetFromStart % session.slotMinutes !== 0) {
      conflicts.push(`Time ${m.pinnedTime} doesn't align with ${session.slotMinutes}-minute slot grid`)
    }

    // Check against other pinned matches
    for (let j = i + 1; j < pinnedMatches.length; j++) {
      const other = pinnedMatches[j]
      const oIdx = matches.indexOf(other)

      if (other.pinnedTime === m.pinnedTime && other.pinnedCourt === m.pinnedCourt) {
        const otherName = `Match #${oIdx + 1}`
        conflicts.push(`Same time and court as ${otherName}`)
        const otherConflicts = pinnedConflicts.get(oIdx) ?? []
        otherConflicts.push(`Same time and court as Match #${mIdx + 1}`)
        pinnedConflicts.set(oIdx, otherConflicts)
      }

      // Player conflict at same time
      if (other.pinnedTime === m.pinnedTime) {
        const mPlayers = m.slots.filter(Boolean)
        const oPlayers = other.slots.filter(Boolean)
        const overlap = mPlayers.filter(p => oPlayers.includes(p))
        if (overlap.length > 0) {
          const playerNames = overlap.map(id => players.find(p => p.id === id)?.name ?? '?').join(', ')
          conflicts.push(`${playerNames} already in Match #${oIdx + 1} at ${m.pinnedTime}`)
          const otherConflicts = pinnedConflicts.get(oIdx) ?? []
          otherConflicts.push(`${playerNames} already in Match #${mIdx + 1} at ${m.pinnedTime}`)
          pinnedConflicts.set(oIdx, otherConflicts)
        }
      }
    }

    if (conflicts.length > 0) pinnedConflicts.set(mIdx, conflicts)
  }

  // Check for fix matches with only 1 player specified on a side
  const singlePlayerPairs: { match: MatchConstraint; side: 'A' | 'B' }[] = []
  for (const m of matches) {
    if (m.mode === 'pinned') continue
    // Check A-side: slots[0] and slots[1]
    const aFilled = (m.slots[0] ? 1 : 0) + (m.slots[1] ? 1 : 0)
    const bFilled = (m.slots[2] ? 1 : 0) + (m.slots[3] ? 1 : 0)
    if (aFilled === 1) {
      singlePlayerPairs.push({ match: m, side: 'A' })
    }
    if (bFilled === 1) {
      singlePlayerPairs.push({ match: m, side: 'B' })
    }
  }

  return {
    hasErrors: tooManyTotal || overloadedPlayers.length > 0 || pinnedConflicts.size > 0,
    tooManyTotal,
    effectiveSlotsNeeded,
    overloadedPlayers,
    pinnedConflicts,
    singlePlayerPairs,
  }
}
