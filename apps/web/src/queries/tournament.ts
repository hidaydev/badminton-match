import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getTournament, listTournaments, createTournament, publishTournament, type TournamentMeta } from './endpoints'
import {
  DEFAULT_TEAM_COURTS,
  type AnyTournamentSnapshot,
  type TeamInfo,
  type TeamMatch,
  type TeamTournamentSnapshot,
} from '../utils/teamTournament'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  GROUP_IDS,
  EMPTY_GROUPS,
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
} from '../utils/tournament'
import { useOptimisticMutation, useOptimisticTournamentMutation } from './useOptimisticMutation'

/** Daftar tournament (metadata) untuk halaman list. */
export function useListTournaments() {
  return useQuery<TournamentMeta[]>({
    queryKey: ['tournaments'],
    queryFn: ({ signal }) => listTournaments(signal),
  })
}

export function useGetTournament(id: string) {
  return useQuery<AnyTournamentSnapshot | null>({
    queryKey: ['tournament', id],
    queryFn: ({ signal }) => getTournament(id, signal),
    enabled: !!id,
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })
}

/** Create tournament (classic/team) → kembalikan { id, snapshot } (id dari Location). */
export function useCreateTournament() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (snap: AnyTournamentSnapshot) => createTournament(snap),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['tournaments'] })
    },
  })
}

export function useConfirmGroups(id: string) {
  return useOptimisticTournamentMutation<{
    localGroups: Record<GroupId, string[]>
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    id,
    (current, { localGroups, name, date, pairs }) => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const propagated = propagateBracket(allMatches, localGroups)
      const newMatches = assignGroupPics(pairs, localGroups, propagated)
      return {
        version: current?.version,
        name,
        date,
        pairs,
        groups: localGroups,
        matches: newMatches,
      }
    },
  )
}

export function useSetTournamentScore(id: string) {
  return useOptimisticTournamentMutation<{ matchId: string; scoreA: number; scoreB: number }>(
    id,
    (current, { matchId, scoreA, scoreB }) => {
      if (!current) return null
      const updated = current.matches.map((m) =>
        m.id === matchId ? { ...m, scoreA, scoreB } : m
      )
      const propagated = propagateBracket(updated, current.groups)
      return { ...current, matches: propagated }
    },
  )
}

export function useResetTournament(id: string) {
  return useOptimisticTournamentMutation<{
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    id,
    (current, { name, date, pairs }) => ({
      version: current?.version,
      name,
      date,
      pairs,
      groups: EMPTY_GROUPS,
      matches: [],
    }),
  )
}

export function useRegeneratePics(id: string) {
  // no optimistic update — result is non-deterministic (random shuffle);
  // applyOptimistic=false → onMutate hanya cancel, throw hanya di mutationFn.
  return useOptimisticTournamentMutation<undefined>(
    id,
    (current) => {
      if (!current) return null
      const newMatches = assignGroupPics(current.pairs, current.groups, current.matches)
      const unassigned = newMatches.some((m) => m.phase === 'group' && !m.picName)
      if (unassigned) throw new Error('Could not assign all PICs — please try again')
      return { ...current, matches: newMatches }
    },
    undefined,
    false,
  )
}

/** Patch snapshot tournament tim yang boleh di-publish. */
export interface TeamTournamentPatch {
  matches?: TeamMatch[]
  teams?: TeamInfo[]
}

/**
 * Publish patch tournament format TEAM lewat jalur queries — memakai optimistic
 * update + OCC retry/rebase yang sama dengan mutation classic di file ini.
 * `version` selalu diambil dari cache agar race-safe (jangan fetch terpisah).
 */
export function usePublishTeamTournament(id: string) {
  return useOptimisticMutation<TeamTournamentSnapshot, TeamTournamentPatch>(
    id,
    {
      queryKey: ['tournament', id],
      fetchSnapshot: async (tournamentId) => {
        const snap = await getTournament(tournamentId)
        return snap && snap.format === 'team' ? snap : null
      },
      publish: async (tournamentId, snap) => {
        const out = await publishTournament(tournamentId, snap)
        return out.format === 'team' ? out : snap
      },
      optimisticUpdate: (current, patch) => {
        if (!current) return null
        return { ...current, ...patch, version: current.version }
      },
      // Editor tim harus selalu selaras server saat save gagal (perilaku lama).
      refetchOnAnyError: true,
    },
  )
}

/** Normalisasi match tim dari server ke bentuk editor (courts & partai dikloning). */
export function normalizeTeamMatches(matches: TeamMatch[]): TeamMatch[] {
  return matches.map((m) => ({
    ...m,
    courts: m.courts ?? [...DEFAULT_TEAM_COURTS],
    partai: m.partai.map((p) => ({ ...p })),
  }))
}
