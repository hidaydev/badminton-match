import type { ScheduleSlot, GameKey, GameScore } from '../types'

/**
 * Field turunan generator yang harus di-reset setiap kali input generator
 * berubah. Dipakai lewat spread supaya literal yang sama tidak disalin di
 * banyak situs. Field situs-spesifik (mis. absentPlayers, fixMatches,
 * cloudSessionId) tetap ditambahkan manual di masing-masing situs.
 */
export const RESET_GENERATED = {
  schedule: [] as ScheduleSlot[],
  lastResult: null,
  playedGames: [] as string[],
  gameScores: {} as Record<GameKey, GameScore>,
}
