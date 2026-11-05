import { createContext, useContext } from 'react'
import type { GeneratorResult } from './generator'
import type {
  FixMatchPatch,
  MatchConstraint,
  NewMatchConstraint,
  Player,
  ScheduleSlot,
  SessionConfig,
} from './types'

export interface WizardDraft {
  /** The community session this draft was published to, if any. */
  serverSessionId: string | null
  session: SessionConfig
  players: Player[]
  fixMatches: MatchConstraint[]
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null
}

export interface WizardStore {
  draft: WizardDraft
  totalGames: number
  slotsPerCourt: number[]
  setTitle: (title: string) => void
  setDate: (date: string) => void
  setCourts: (courts: number) => void
  setSessionStart: (time: string) => void
  setSlotMinutes: (minutes: number) => void
  setCourtTime: (index: number, start: string, end: string) => void
  setCourtName: (index: number, name: string) => void
  setPlayerCount: (count: number) => void
  lockSession: () => void
  resetDraft: () => void
  setServerSession: (id: string | null) => void
  addPlayer: (player: Omit<Player, 'id'>) => void
  addPlayers: (players: Omit<Player, 'id'>[]) => void
  updatePlayer: (id: string, patch: Partial<Omit<Player, 'id'>>) => void
  removePlayer: (id: string) => void
  addFixMatch: (match: NewMatchConstraint) => void
  updateFixMatch: (id: string, patch: FixMatchPatch) => void
  duplicateFixMatch: (id: string) => void
  removeFixMatch: (id: string) => void
  setResult: (result: GeneratorResult) => void
}

export const WizardContext = createContext<WizardStore | null>(null)

export function useWizard(): WizardStore {
  const value = useContext(WizardContext)
  if (value === null) throw new Error('useWizard must be used inside WizardProvider')
  return value
}
