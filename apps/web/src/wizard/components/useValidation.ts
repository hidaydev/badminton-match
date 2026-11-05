import { t } from '../../i18n'
import { useWizard } from '../context'
import { timeToMinutes } from '../time'
import type { MatchConstraint, Player } from '../types'
import { PLAYERS_PER_GAME } from '../types'

export interface ValidationResult {
  hasErrors: boolean
  tooManyTotal: boolean
  effectiveSlotsNeeded: number
  overloadedPlayers: { player: Player; count: number; max: number }[]
  pinnedConflicts: Map<number, string[]>
  singlePlayerPairs: { match: MatchConstraint; side: 'A' | 'B' }[]
}

export function useValidation(players: Player[], matches: MatchConstraint[]): ValidationResult {
  const { draft, totalGames } = useWizard()
  const session = draft.session
  const expectedPlays = players.length > 0 ? Math.round((totalGames * PLAYERS_PER_GAME) / players.length) : 0

  const counts: Record<string, number> = {}
  for (const match of matches) {
    for (const id of match.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  const pairableCount = matches.filter(
    (match) => match.mode !== 'pinned' && !!(match.slots[0] && match.slots[1] && !match.slots[2] && !match.slots[3]),
  ).length
  const pinnedCount = matches.filter((match) => match.mode === 'pinned').length
  const nonPairableCount = matches.filter((match) => match.mode !== 'pinned').length - pairableCount
  const effectiveSlotsNeeded = Math.ceil(pairableCount / 2) + nonPairableCount + pinnedCount
  const tooManyTotal = effectiveSlotsNeeded > totalGames
  const overloadedPlayers = players
    .map((player) => ({ player, count: counts[player.id] ?? 0, max: expectedPlays }))
    .filter(({ count, max }) => count > max)

  const pinnedConflicts = new Map<number, string[]>()
  const pinnedMatches = matches.filter((match): match is Extract<MatchConstraint, { mode: 'pinned' }> => match.mode === 'pinned')

  for (let i = 0; i < pinnedMatches.length; i++) {
    const match = pinnedMatches[i]
    const matchIndex = matches.indexOf(match)
    const conflicts: string[] = []

    if (!match.pinnedTime) {
      conflicts.push(t('wizard.constraints.validation.conflictTime'))
      pinnedConflicts.set(matchIndex, conflicts)
      continue
    }

    const offsetFromStart = timeToMinutes(match.pinnedTime) - timeToMinutes(session.sessionStart)
    if (offsetFromStart % session.slotMinutes !== 0) {
      conflicts.push(t('wizard.constraints.validation.conflictAlign', { time: match.pinnedTime, minutes: session.slotMinutes }))
    }

    for (let j = i + 1; j < pinnedMatches.length; j++) {
      const other = pinnedMatches[j]
      const otherIndex = matches.indexOf(other)

      if (other.pinnedTime === match.pinnedTime && other.pinnedCourt === match.pinnedCourt) {
        conflicts.push(t('wizard.constraints.validation.conflictSame', { n: otherIndex + 1 }))
        const otherConflicts = pinnedConflicts.get(otherIndex) ?? []
        otherConflicts.push(t('wizard.constraints.validation.conflictSame', { n: matchIndex + 1 }))
        pinnedConflicts.set(otherIndex, otherConflicts)
      }

      if (other.pinnedTime === match.pinnedTime) {
        const overlap = match.slots.filter((id) => id && other.slots.includes(id))
        if (overlap.length > 0) {
          const names = overlap.map((id) => players.find((player) => player.id === id)?.name ?? '?').join(', ')
          conflicts.push(t('wizard.constraints.validation.conflictPlayer', { names, n: otherIndex + 1, time: match.pinnedTime }))
          const otherConflicts = pinnedConflicts.get(otherIndex) ?? []
          otherConflicts.push(t('wizard.constraints.validation.conflictPlayer', { names, n: matchIndex + 1, time: match.pinnedTime }))
          pinnedConflicts.set(otherIndex, otherConflicts)
        }
      }
    }

    if (conflicts.length > 0) pinnedConflicts.set(matchIndex, conflicts)
  }

  const singlePlayerPairs: { match: MatchConstraint; side: 'A' | 'B' }[] = []
  for (const match of matches) {
    if (match.mode === 'pinned') continue
    const aFilled = (match.slots[0] ? 1 : 0) + (match.slots[1] ? 1 : 0)
    const bFilled = (match.slots[2] ? 1 : 0) + (match.slots[3] ? 1 : 0)
    if (aFilled === 1) singlePlayerPairs.push({ match, side: 'A' })
    if (bFilled === 1) singlePlayerPairs.push({ match, side: 'B' })
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

