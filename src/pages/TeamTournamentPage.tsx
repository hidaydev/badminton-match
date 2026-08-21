import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useGetTournament } from '../queries'
import { publishTournament } from '../queries/endpoints'
import {
  computeTeamStandings,
  generateTeamDraw,
  teamMatchOutcome,
  teamTarget,
  type TeamMatch,
  type TeamTournamentSnapshot,
} from '../utils/teamTournament'

type Tab = 'klasemen' | 'jadwal' | 'final'

/** Halaman tournament format TIM: klasemen, undian, jadwal skor partai, final. */
export default function TeamTournamentPage() {
  const { id = '' } = useParams()
  const queryClient = useQueryClient()
  const { data, isFetching } = useGetTournament(id)
  const snap = data && data.format === 'team' ? data : null

  const [tab, setTab] = useState<Tab>('klasemen')
  const [localMatches, setLocalMatches] = useState<TeamMatch[] | null>(null)
  const [prevSnap, setPrevSnap] = useState<TeamTournamentSnapshot | null>(null)
  const [publishError, setPublishError] = useState<string | null>(null)
  const [editingTeamId, setEditingTeamId] = useState<string | null>(null)
  const [editingTeamName, setEditingTeamName] = useState('')

  // Sinkronkan editor dengan snapshot server saat refetch (pola "adjust state
  // during render" — rekomendasi React, bukan setState di effect).
  if (snap && snap !== prevSnap) {
    setPrevSnap(snap)
    setLocalMatches(snap.matches.map((m) => ({ ...m, partai: m.partai.map((p) => ({ ...p })) })))
  }

  const publish = useMutation({
    mutationFn: async (matches: TeamMatch[]) => {
      if (!snap) throw new Error('no data')
      const next: TeamTournamentSnapshot = { ...snap, version: snap.version, matches }
      return await publishTournament(id, next)
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['tournament', id] })
      setPublishError(null)
    },
    onError: (err) => {
      setPublishError(err instanceof Error ? err.message : 'Failed to save.')
    },
  })

  useEffect(() => {
    if (!publishError) return
    const t = setTimeout(() => setPublishError(null), 5000)
    return () => clearTimeout(t)
  }, [publishError])

  if (!snap) {
    return <p className="text-fg-dim text-sm">{isFetching ? 'Loading team tournament…' : 'Tournament not found.'}</p>
  }

  const teams = snap.teams
  const standings = computeTeamStandings(teams, localMatches ?? snap.matches)
  const groupMatches = (localMatches ?? snap.matches).filter((m) => m.phase === 'group')
  const finalMatch = (localMatches ?? snap.matches).find((m) => m.phase === 'final')
  const groupComplete = groupMatches.length === 9 && groupMatches.every((m) => teamMatchOutcome(m).complete)
  const hasFinal = !!finalMatch

  const startEditTeamName = (teamId: string, currentName: string) => {
    setEditingTeamId(teamId)
    setEditingTeamName(currentName)
  }

  const saveTeamName = () => {
    if (editingTeamId && editingTeamName.trim()) {
      // Update team name in snapshot
      const updatedTeams = teams.map((t) =>
        t.id === editingTeamId ? { ...t, name: editingTeamName.trim() } : t
      )
      const next: TeamTournamentSnapshot = { ...snap, teams: updatedTeams }
      publishTournament(id, next).then(() => {
        queryClient.invalidateQueries({ queryKey: ['tournament', id] })
      })
    }
    setEditingTeamId(null)
    setEditingTeamName('')
  }

  // Final match result
  const finalOutcome = finalMatch ? teamMatchOutcome(finalMatch) : null
  const championId = finalOutcome?.complete
    ? finalOutcome.aWins > finalOutcome.bWins
      ? finalMatch!.teamA
      : finalMatch!.teamB
    : null
  const championName = championId ? teamName(teams, championId) : null

  const saveMatches = (matches: TeamMatch[]) => {
    setLocalMatches(matches)
    publish.mutate(matches)
  }

  const handleUndian = () => {
    const ids = teams.map((t) => t.id)
    const draw = generateTeamDraw(ids)
    const matches: TeamMatch[] = draw.map(([a, b], i) => ({
      id: `g-${i + 1}`,
      phase: 'group',
      teamA: a,
      teamB: b,
      partai: [{ scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }],
      courts: ['Court 1', 'Court 2', 'Court 3'],
    }))
    saveMatches(matches)
    setTab('jadwal')
  }

  const handleBuatFinal = () => {
    if (!groupComplete || hasFinal) return
    const [first, second] = standings
    if (!first || !second) return
    const final: TeamMatch = {
      id: 'final',
      phase: 'final',
      teamA: first.teamId,
      teamB: second.teamId,
      partai: [{ scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }],
      courts: ['Court 1', 'Court 2', 'Court 3'],
    }
    saveMatches([...(localMatches ?? snap.matches), final])
    setTab('final')
  }

  const updatePartai = (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => {
    if (!localMatches) return
    const matches = localMatches.map((m, i) =>
      i === matchIdx
        ? { ...m, partai: m.partai.map((p, j) => (j === partaiIdx ? { ...p, ...patch } : p)) }
        : m
    )
    setLocalMatches(matches)
  }

  const updateCourt = (matchIdx: number, courtIdx: number, name: string) => {
    if (!localMatches) return
    const matches = localMatches.map((m, i) => {
      if (i !== matchIdx) return m
      const courts = [...(m.courts ?? ['Court 1', 'Court 2', 'Court 3'])]
      courts[courtIdx] = name
      return { ...m, courts: courts as [string, string, string] }
    })
    setLocalMatches(matches)
  }

  const tabs: { id: Tab; label: string }[] = [
    { id: 'klasemen', label: 'Standings' },
    { id: 'jadwal', label: 'Schedule' },
    { id: 'final', label: 'Final' },
  ]

  return (
    <div className="flex flex-col gap-0 -mx-3 -mt-4">
      {publishError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg" role="alert">
          {publishError}
        </div>
      )}
      <div className="bg-surface px-4 pt-3 pb-0 border-b border-border-subtle">
        <div className="flex items-center gap-2">
          <h2 className="text-[1rem] font-bold text-fg leading-tight">{snap.name}</h2>
          {publish.isPending && <span className="text-xs text-fg-dim font-mono">saving…</span>}
        </div>
        <p className="text-xs text-fg-dim mt-0.5 mb-3 font-mono">
          {snap.date} · 6 teams · 3 doubles · rally {teamTarget('group')}/{teamTarget('final')}
        </p>
        <div className="flex">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex-1 py-2.5 text-sm font-semibold border-b-2 transition-colors ${
                tab === t.id ? 'text-accent border-accent' : 'text-fg-dim border-transparent hover:text-fg'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      <div className="px-3 pt-4 pb-8 flex flex-col gap-3">
        {tab === 'klasemen' && (
          <>
            <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
              <div className="px-4 py-2 border-b border-border-subtle text-xs font-mono text-fg-dim uppercase tracking-wider">
                Standings
              </div>
              {standings.map((r, i) => {
                const isTop = i < 2 && groupComplete
                const isChampion = championId === r.teamId
                const team = teams.find((t) => t.id === r.teamId)
                const isEditing = editingTeamId === r.teamId
                return (
                  <div key={r.teamId} className={`border-b border-border-subtle last:border-0 ${isTop ? 'bg-accent/5' : ''}`}>
                    <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5 px-4 py-2.5">
                      <span className={`w-5 text-sm font-mono shrink-0 ${i === 0 ? 'text-accent' : i === 1 ? 'text-slate-200' : 'text-fg-dim'}`}>
                        {i === 0 && isChampion ? '👑' : i + 1}
                      </span>
                      {isEditing ? (
                        <input
                          autoFocus
                          value={editingTeamName}
                          onChange={(e) => setEditingTeamName(e.target.value)}
                          onBlur={saveTeamName}
                          onKeyDown={(e) => { if (e.key === 'Enter') saveTeamName(); if (e.key === 'Escape') setEditingTeamId(null) }}
                          className="flex-1 bg-elevated border border-accent rounded px-2 py-0.5 text-sm text-fg focus:outline-none min-w-0"
                        />
                      ) : (
                        <span
                          className="flex-1 text-sm text-fg truncate cursor-pointer hover:text-accent transition-colors group"
                          onClick={() => startEditTeamName(r.teamId, r.teamName)}
                        >
                          {r.teamName}
                          <span className="inline-block ml-1.5 text-fg-dim group-hover:text-accent opacity-0 group-hover:opacity-100 transition-opacity">
                            ✎
                          </span>
                        </span>
                      )}
                      <span className="text-xs text-fg-dim font-mono shrink-0">
                        {r.points}pt · {r.teamWins}-{r.teamLosses} · {r.pointsFor}-{r.pointsAgainst}
                      </span>
                    </div>
                    {/* Team members */}
                    {team && team.players.length > 0 && (
                      <div className="px-4 pb-2.5 pt-0 flex flex-wrap gap-x-3 gap-y-0.5">
                        {team.players.map((p) => (
                          <span key={p.name} className="text-[10px] font-mono text-fg-dim">
                            <span className="text-accent">{p.cls}</span> {p.name}
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
            {groupMatches.length === 0 && (
              <button
                onClick={handleUndian}
                disabled={publish.isPending}
                className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
              >
                Group Draw (match day)
              </button>
            )}
            {groupComplete && !hasFinal && (
              <button
                onClick={handleBuatFinal}
                disabled={publish.isPending}
                className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
              >
                Create Final (top 2)
              </button>
            )}
            {!groupComplete && groupMatches.length > 0 && (
              <p className="text-xs text-fg-dim text-center">Finish all 9 group matches to determine the final.</p>
            )}
          </>
        )}

        {tab === 'jadwal' && (
          <>
            {groupMatches.length === 0 && (
              <button
                onClick={handleUndian}
                disabled={publish.isPending}
                className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
              >
                Group Draw (match day)
              </button>
            )}
            {groupMatches.map((m, mi) => (
              <MatchCard
                key={m.id}
                match={m}
                teams={teams}
                saving={publish.isPending}
                onChange={(_, pi, patch) => updatePartai(mi, pi, patch)}
                onUpdateCourt={(matchIdx, courtIdx, name) => updateCourt(matchIdx, courtIdx, name)}
                matchIdx={mi}
                onSave={() => localMatches && saveMatches(localMatches)}
              />
            ))}
          </>
        )}

        {tab === 'final' && (
          <>
            {finalMatch ? (
              <>
                {/* Champion banner */}
                {finalOutcome?.complete && championName && (
                  <div className="bg-linear-to-r from-accent/20 via-accent/10 to-accent/20 border border-accent/30 rounded-lg px-4 py-3 text-center">
                    <p className="text-[10px] font-mono text-accent uppercase tracking-widest mb-1">Champion</p>
                    <p className="text-lg font-bold text-fg">🏆 {championName}</p>
                    <p className="text-xs text-fg-dim mt-0.5">
                      {finalOutcome.aWins} - {finalOutcome.bWins}
                    </p>
                  </div>
                )}
                <MatchCard
                  key={finalMatch.id}
                  match={finalMatch}
                  teams={teams}
                  saving={publish.isPending}
                  onChange={(_, pi, patch) => updatePartai((localMatches ?? snap.matches).findIndex((x) => x.id === finalMatch.id), pi, patch)}
                  onUpdateCourt={(matchIdx, courtIdx, name) => updateCourt(matchIdx, courtIdx, name)}
                  matchIdx={(localMatches ?? snap.matches).findIndex((x) => x.id === finalMatch.id)}
                  onSave={() => localMatches && saveMatches(localMatches)}
                />
              </>
            ) : (
              <p className="text-fg-dim text-xs text-center py-8">
                {groupComplete ? 'Click "Create Final" in the Standings tab.' : 'Finish the group phase first.'}
              </p>
            )}
          </>
        )}
      </div>
    </div>
  )
}

function teamName(teams: { id: string; name: string }[], id: string | undefined): string {
  return teams.find((t) => t.id === id)?.name ?? (id ?? '—')
}

function MatchCard({
  match,
  teams,
  saving,
  matchIdx,
  onChange,
  onUpdateCourt,
  onSave,
}: {
  match: TeamMatch
  teams: { id: string; name: string; players: { name: string; cls: string }[] }[]
  saving: boolean
  matchIdx: number
  onChange: (matchIdx: number, partaiIdx: number, patch: Partial<{ scoreA: number | null; scoreB: number | null }>) => void
  onUpdateCourt: (matchIdx: number, courtIdx: number, name: string) => void
  onSave: () => void
}) {
  const out = teamMatchOutcome(match)
  const target = teamTarget(match.phase)
  const dirty = match.partai.some((p) => p.scoreA !== null || p.scoreB !== null)
  const label = match.phase === 'final' ? `FINAL · ${teamName(teams, match.teamA)} vs ${teamName(teams, match.teamB)}` : `Group · ${teamName(teams, match.teamA)} vs ${teamName(teams, match.teamB)}`

  const getTeamPlayer = (teamId: string, cls: string) => {
    const team = teams.find((t) => t.id === teamId)
    return team?.players.find((p) => p.cls === cls)?.name ?? '—'
  }

  const partaiClasses = ['C+', 'A+', 'B+']
  const courts = match.courts ?? ['Court 1', 'Court 2', 'Court 3']

  return (
    <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
      <div className="flex items-center justify-between px-4 py-2 border-b border-border-subtle">
        <span className="text-xs font-mono text-fg-dim uppercase tracking-wider">{label}</span>
        {dirty && (
          <span className="text-[10px] font-mono text-fg-dim">
            {out.complete ? `${out.aWins}-${out.bWins}` : 'incomplete'}
          </span>
        )}
      </div>
      <div className="px-4 py-3 flex flex-col gap-3">
        {partaiClasses.map((cls, pi) => {
          const pair = cls === 'C+' ? 'C' : cls === 'A+' ? 'A' : 'B'
          return (
            <div key={pi} className="flex flex-col gap-1">
              <div className="flex items-center gap-2">
                <span className="w-12 text-[10px] font-mono text-fg-dim uppercase shrink-0">{cls} {pair}</span>
                <span className="flex-1 text-[10px] font-mono text-fg-dim truncate">
                  {getTeamPlayer(match.teamA, cls)}/{getTeamPlayer(match.teamA, pair)}
                </span>
                <input
                  type="number"
                  min={0}
                  max={target}
                  value={match.partai[pi].scoreA ?? ''}
                  onChange={(e) => onChange(matchIdx, pi, { scoreA: e.target.value === '' ? null : Math.max(0, Number(e.target.value)) })}
                  className="w-14 bg-elevated border border-border rounded-md px-2 py-1.5 text-sm font-mono text-fg text-center focus:border-accent focus:outline-none"
                  aria-label={`Score ${teamName(teams, match.teamA)} partai ${pi + 1}`}
                />
                <span className="text-fg-dim text-xs shrink-0">:</span>
                <input
                  type="number"
                  min={0}
                  max={target}
                  value={match.partai[pi].scoreB ?? ''}
                  onChange={(e) => onChange(matchIdx, pi, { scoreB: e.target.value === '' ? null : Math.max(0, Number(e.target.value)) })}
                  className="w-14 bg-elevated border border-border rounded-md px-2 py-1.5 text-sm font-mono text-fg text-center focus:border-accent focus:outline-none"
                  aria-label={`Score ${teamName(teams, match.teamB)} partai ${pi + 1}`}
                />
                <span className="flex-1 text-[10px] font-mono text-fg-dim truncate text-right">
                  {getTeamPlayer(match.teamB, cls)}/{getTeamPlayer(match.teamB, pair)}
                </span>
              </div>
              {/* Court assignment */}
              <div className="flex items-center gap-2 pl-12">
                <span className="text-[9px] font-mono text-fg-dim">📍</span>
                <input
                  type="text"
                  value={courts[pi]}
                  onChange={(e) => onUpdateCourt(matchIdx, pi, e.target.value)}
                  className="flex-1 bg-transparent text-[10px] font-mono text-fg-dim border-b border-border-subtle focus:border-accent focus:outline-none"
                  placeholder={`Court ${pi + 1}`}
                />
              </div>
            </div>
          )
        })}
      </div>
      <div className="px-4 pb-3">
        <button
          onClick={onSave}
          disabled={saving || !dirty}
          className="w-full py-2 rounded-lg bg-accent/15 border border-accent/30 text-accent text-sm font-bold disabled:opacity-40"
        >
          {saving ? 'Saving…' : 'Save'}
        </button>
      </div>
    </div>
  )
}
