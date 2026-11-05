import type { Player, ScheduleSlot, GameScore, GameKey } from '../types'
import { toGameKey } from '../types'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort, type TallyRow } from './tally'

export interface PlayerStanding extends TallyRow {
  player: Player
}

export function computeStandings(
  players: Player[],
  schedule: ScheduleSlot[],
  gameScores: Record<GameKey, GameScore>,
  voidPlayerIds?: Iterable<string>,
  skippedPlayers?: Record<string, string[]>,
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()
  // Semantik skip_player (MIRROR rating engine — domain.MatchRateable):
  // game dengan pemain absent/skipped TETAP dihitung untuk pemain yang
  // benar-benar main — hanya pemain void (absent/placeholder) yang di-exclude
  // dari tally. Skip per-game ditambah sebagai void per game (union dengan
  // void global).
  //
  // Satu tim BOLEH kosong di tally selama ia masih punya pemain real: kasus
  // nyata "dua pemain di-skip" = mereka digantikan orang lain dan skornya tetap
  // sah, jadi tim lawan tetap mendapat game-nya. Game dibuang bila salah satu
  // tim tidak punya pemain real sama sekali (mis. seluruhnya placeholder /
  // absent global), atau kedua tim tidak punya pemain eligible (mis. semua
  // pemain di-skip).
  const voidSet = voidPlayerIds ? new Set(voidPlayerIds) : null
  // Pemain real yang hadir. Daftar `players` dari pemanggil sudah tidak memuat
  // pemain absent global & placeholder; pemain yang di-skip per game tetap ada
  // di sini (mereka hadir, hanya digantikan di game tersebut).
  const realIds = new Set<string>(players.map((p) => p.id))

  for (const p of players) {
    map.set(p.id, { ...initTallyRow(), player: p })
  }

  for (const slot of schedule) {
    const key = toGameKey(slot.slot, slot.court)
    const score = gameScores[key]
    if (!score) continue

    // Per-game skipped union
    let skipSet: Set<string> | null = null
    if (skippedPlayers?.[key]?.length) skipSet = new Set(skippedPlayers[key])

    const teamA = (() => {
      let a = voidSet ? slot.teamA.filter((id) => !voidSet.has(id)) : [...slot.teamA]
      if (skipSet) a = a.filter((id) => !skipSet!.has(id))
      return a
    })()
    const teamB = (() => {
      let b = voidSet ? slot.teamB.filter((id) => !voidSet.has(id)) : [...slot.teamB]
      if (skipSet) b = b.filter((id) => !skipSet!.has(id))
      return b
    })()
    // Tanpa pemain real di salah satu sisi (placeholder/absent semua) → drop.
    if (!slot.teamA.some((id) => realIds.has(id)) || !slot.teamB.some((id) => realIds.has(id))) continue
    // Kedua sisi kosong setelah void/skip → tidak ada yang bisa ditallikan.
    if (teamA.length === 0 && teamB.length === 0) continue

    const { a, b } = score

    for (const id of teamA) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, a, b)
    }

    for (const id of teamB) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, b, a)
    }
  }

  for (const standing of map.values()) computeDiff(standing)

  return [...map.values()].sort((a, b) =>
    standardStandingSort(a, b) || a.player.name.localeCompare(b.player.name)
  )
}
