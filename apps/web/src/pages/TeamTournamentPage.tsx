import { useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useGetTournament } from '../queries'
import { publishTournament } from '../queries/endpoints'
import {
  computeTeamStandings,
  generateTeamDraw,
  teamMatchOutcome,
  teamMatchDirty,
  teamTarget,
  teamName,
  teamLogoPath,
  buildTeamsByDraw,
  DEFAULT_TEAM_COURTS,
  TEAM_NAMES,
  PARTAI_CLASSES,
  type TeamMatch,
  type TeamInfo,
  type TeamTournamentSnapshot,
} from '../utils/teamTournament'
import TeamMatchCard from '../components/tournament/TeamMatchCard'
import TeamGroupSchedule from '../components/tournament/TeamGroupSchedule'
import { drawMatchPost, drawTeamMatchPost, drawPositionPost, loadImage, type TeamMatchPartaiRow } from '../utils/canvasPost'
import { canvasToBlob, shareOrDownload } from '../utils/share'
import { loadOverlayImages } from '../utils/overlays'

type Tab = 'klasemen' | 'jadwal' | 'final'

/** Index named team (0..5) dari nama kanonik; fallback ke index slot. */
const namedIdx = (name: string, fallback: number): number => {
  const k = (TEAM_NAMES as readonly string[]).indexOf(name)
  return k === -1 ? fallback : k
}

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
  // Undian hari-H: index = slot, value = index named team (0..5). null = belum diedit.
  const [slotToNamed, setSlotToNamed] = useState<number[] | null>(null)
  const [finalPhotos, setFinalPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [overlays, setOverlays] = useState<Record<string, HTMLImageElement | undefined>>({})
  const finalFileInputRef = useRef<HTMLInputElement>(null)
  const activeFinalKey = useRef<string | null>(null)

  // Schedule-tab photo state — lifted here so photos survive tab switches
  const [schedulePartaiPhotos, setSchedulePartaiPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [schedulePostModeMatches, setSchedulePostModeMatches] = useState<Record<string, boolean>>({})

  useEffect(() => {
    loadOverlayImages({
      logo: '/majadu-logo.png',
      badge: '/tournament-badge.png',
      chevrons: '/chevrons.png',
      sponsor: '/sponsor-logo.png',
      summaryBg: '/summary-bg.jpg',
      cardLogo: '/anniversary-card-logo.png',
    }).then(setOverlays)
  }, [])

  // Sinkronkan editor dengan snapshot server saat refetch (pola "adjust state
  // during render" — rekomendasi React, bukan setState di effect).
  if (snap && snap !== prevSnap) {
    setPrevSnap(snap)
    setLocalMatches(snap.matches.map((m) => ({
      ...m,
      courts: m.courts ?? [...DEFAULT_TEAM_COURTS],
      partai: m.partai.map((p) => ({ ...p })),
    })))
    setSlotToNamed(snap.teams.map((t, i) => namedIdx(t.name, i)))
  }

  const publish = useMutation({
    mutationFn: async (patch: { matches?: TeamMatch[]; teams?: TeamInfo[] }) => {
      const currentSnap = queryClient.getQueryData<TeamTournamentSnapshot>(['tournament', id])
      if (!currentSnap || currentSnap.format !== 'team') throw new Error('no data')
      const next: TeamTournamentSnapshot = { ...currentSnap, version: currentSnap.version, ...patch }
      return await publishTournament(id, next)
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['tournament', id] })
      setPublishError(null)
    },
    onError: (err) => {
      setPublishError(err instanceof Error ? err.message : 'Failed to save.')
      if (snap?.matches) {
        setLocalMatches(snap.matches.map((m) => ({
          ...m,
          courts: m.courts ?? [...DEFAULT_TEAM_COURTS],
          partai: m.partai.map((p) => ({ ...p })),
        })))
      }
      queryClient.invalidateQueries({ queryKey: ['tournament', id] })
    },
  })

  useEffect(() => {
    if (!publishError) return
    const t = setTimeout(() => setPublishError(null), 5000)
    return () => clearTimeout(t)
  }, [publishError])

  const teams = useMemo(() => snap?.teams ?? [], [snap?.teams])
  const matches = useMemo(() => localMatches ?? snap?.matches ?? [], [localMatches, snap?.matches])
  const standings = useMemo(() => computeTeamStandings(teams, matches), [teams, matches])
  const groupMatches = useMemo(() => matches.filter((m) => m.phase === 'group'), [matches])
  const finalMatch = useMemo(() => matches.find((m) => m.phase === 'final'), [matches])
  // dirty = match lokal beda dari snapshot server (skor atau court).
  const dirtyByMatchId = useMemo(() => {
    const serverById = new Map((snap?.matches ?? []).map((m) => [m.id, m]))
    const out: Record<string, boolean> = {}
    for (const m of matches) out[m.id] = teamMatchDirty(m, serverById.get(m.id))
    return out
  }, [matches, snap?.matches])

  if (!snap) {
    return <p className="text-fg-dim text-sm">{isFetching ? 'Loading team tournament…' : 'Tournament not found.'}</p>
  }
  const groupComplete = groupMatches.length === 9 && groupMatches.every((m) => teamMatchOutcome(m).complete)
  const hasFinal = !!finalMatch

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
    publish.mutate({ matches })
  }

  // Undian manual hari-H: named team → dapat slot berapa. Memilih slot yang
  // sudah terpakai akan menukar (bijection 6 named team ↔ 6 slot).
  const assignDrawSlot = (namedK: number, slotIdx: number) => {
    setSlotToNamed((prev) => {
      if (!prev) return prev
      const cur = prev.indexOf(namedK)
      if (cur === -1 || cur === slotIdx) return prev
      const next = [...prev]
      next[cur] = next[slotIdx]
      next[slotIdx] = namedK
      return next
    })
  }

  const handleUndian = () => {
    const ids = teams.map((t) => t.id)
    const draw = generateTeamDraw(ids)
    const matches: TeamMatch[] = draw.map(([a, b, court], i) => ({
      id: `g-${i + 1}`,
      phase: 'group',
      teamA: a,
      teamB: b,
      partai: [{ scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }, { scoreA: null, scoreB: null }],
      courts: [court, court, court],
    }))
    // Pindahkan ENTRI tim (id slot + nama + roster) sesuai undian, bukan cuma
    // label — supaya roster ikut nama ke mana pun tim ditempatkan.
    const perm = slotToNamed ?? teams.map((_, i) => i)
    const namedTeams = buildTeamsByDraw(teams, perm)
    setLocalMatches(matches)
    publish.mutate({ matches, teams: namedTeams })
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
      courts: ['Court 12', 'Court 12', 'Court 12'],
    }
    saveMatches([...(localMatches ?? snap.matches), final])
    setTab('final')
  }

  const getFinalPairName = (teamId: string, clsA: string, clsB: string): string => {
    const team = teams.find((t) => t.id === teamId)
    const p1 = team?.players.find((p) => p.cls === clsA)?.name ?? '—'
    const p2 = team?.players.find((p) => p.cls === clsB)?.name ?? '—'
    return `${p1}/${p2}`
  }

  const handleFinalDownload = async () => {
    if (!finalMatch) return
    const out = teamMatchOutcome(finalMatch)
    const tNameA = teamName(teams, finalMatch.teamA)
    const tNameB = teamName(teams, finalMatch.teamB)
    const files: File[] = []

    const [teamALogoImg, teamBLogoImg] = await Promise.all([
      teamLogoPath(tNameA) ? loadImage(teamLogoPath(tNameA)!).catch(() => undefined) : Promise.resolve(undefined),
      teamLogoPath(tNameB) ? loadImage(teamLogoPath(tNameB)!).catch(() => undefined) : Promise.resolve(undefined),
    ])

    for (let pi = 0; pi < PARTAI_CLASSES.length; pi++) {
      const key = `partai-${pi}`
      const photo = finalPhotos[key]
      const p = finalMatch.partai[pi]
      if (!photo || p.scoreA === null || p.scoreB === null) continue
      const [clsA, clsB] = PARTAI_CLASSES[pi]
      const nameA = getFinalPairName(finalMatch.teamA, clsA, clsB)
      const nameB = getFinalPairName(finalMatch.teamB, clsA, clsB)
      const c = document.createElement('canvas')
      drawMatchPost(c, photo, nameA, nameB, p.scoreA, p.scoreB, `FINAL · ${clsA}${clsB}`, overlays.logo, overlays.badge, overlays.chevrons, overlays.sponsor, overlays.cardLogo, teamALogoImg, teamBLogoImg, 'MAJADU 1\u02E2\u1D57 ANNIVERSARY  \u2022  MAJADU 1\u02E2\u1D57 ANNIVERSARY')
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], `final-${clsA}${clsB}.jpg`, { type: 'image/jpeg' }))
    }

    // Summary post — no photo needed, always generated
    const partaiRows: TeamMatchPartaiRow[] = PARTAI_CLASSES.map(([clsA, clsB], pi) => ({
      tier: `${clsA}${clsB}`,
      nameA: getFinalPairName(finalMatch.teamA, clsA, clsB),
      nameB: getFinalPairName(finalMatch.teamB, clsA, clsB),
      scoreA: finalMatch.partai[pi].scoreA,
      scoreB: finalMatch.partai[pi].scoreB,
    }))
    const summaryCanvas = document.createElement('canvas')
    drawTeamMatchPost(summaryCanvas, tNameA, tNameB, out.aWins, out.bWins, partaiRows, 'FINAL', overlays.summaryBg, overlays.logo, overlays.sponsor, overlays.cardLogo, teamALogoImg, teamBLogoImg)
    const summaryBlob = await canvasToBlob(summaryCanvas)
    if (summaryBlob) files.push(new File([summaryBlob], 'final-summary.jpg', { type: 'image/jpeg' }))

    const champPhoto = finalPhotos['champion']
    if (champPhoto && championName) {
      const champLogoImg = teamLogoPath(championName)
        ? await loadImage(teamLogoPath(championName)!).catch(() => undefined)
        : undefined
      const c = document.createElement('canvas')
      drawPositionPost(c, champPhoto, '🏆 CHAMPION', championName, overlays.logo, overlays.chevrons, overlays.sponsor, overlays.badge, overlays.cardLogo, champLogoImg)
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], 'champion.jpg', { type: 'image/jpeg' }))
    }

    if (files.length > 0) await shareOrDownload(files, championName ? `Final · ${championName}` : 'Final')
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

  const updateCourt = (matchIdx: number, name: string) => {
    if (!localMatches) return
    // Satu court per team-match → semua partai memakai court yang sama.
    setLocalMatches(localMatches.map((m, i) =>
      i === matchIdx ? { ...m, courts: [name, name, name] as [string, string, string] } : m))
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
          {publish.isPending && <span className="text-xs text-fg-dim">saving…</span>}
        </div>
        <p className="text-xs text-fg-dim mt-0.5 mb-3">
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
              <div className="px-4 py-2 border-b border-border-subtle text-xs text-fg-dim uppercase tracking-wider">
                Standings
              </div>
              {standings.map((r, i) => {
                const isTop = i < 2 && groupComplete
                const isChampion = championId === r.teamId
                const team = teams.find((t) => t.id === r.teamId)
                return (
                  <div key={r.teamId} className={`border-b border-border-subtle last:border-0 ${isTop ? 'bg-accent/5' : ''}`}>
                    <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5 px-4 py-2.5">
                      <span className={`w-5 text-sm font-sans shrink-0 ${i === 0 ? 'text-accent' : i === 1 ? 'text-slate-200' : 'text-fg-dim'}`}>
                        {i === 0 && isChampion ? '👑' : i + 1}
                      </span>
                      {/* Nama tim fixed & terkunci (dipilih saat registrasi) — tidak bisa diedit di sini. */}
                      <span className="flex-1 text-sm text-fg truncate">{r.teamName}</span>
                      <span className="text-xs text-fg-dim font-sans shrink-0">
                        {r.points}pt · {r.teamWins}-{r.teamLosses} · {r.pointsFor}-{r.pointsAgainst}
                      </span>
                    </div>
                    {/* Team members */}
                    {team && team.players.length > 0 && (
                      <div className="px-4 pb-2.5 pt-0 flex flex-wrap gap-x-3 gap-y-0.5">
                        {team.players.map((p) => (
                          <span key={p.name} className="text-[10px] text-fg-dim">
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
              <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
                <div className="px-4 py-2 border-b border-border-subtle text-xs text-fg-dim uppercase tracking-wider">
                  Team Draw (match day)
                </div>
                {TEAM_NAMES.map((name, k) => {
                  const slot = (slotToNamed ?? teams.map((_, i) => i)).indexOf(k)
                  return (
                    <div key={name} className="flex items-center gap-3 px-4 py-2 border-b border-border-subtle last:border-0">
                      <span className="flex-1 text-sm text-fg truncate">{name}</span>
                      <select
                        value={String(slot)}
                        onChange={(e) => assignDrawSlot(k, Number(e.target.value))}
                        className="w-28 bg-elevated border border-border rounded-md px-2 py-1.5 text-sm text-fg focus:border-accent focus:outline-none cursor-pointer"
                        aria-label={`Slot untuk ${name}`}
                      >
                        {TEAM_NAMES.map((_, si) => (
                          <option key={si} value={si}>Tim {si + 1}</option>
                        ))}
                      </select>
                    </div>
                  )
                })}
                <div className="p-3">
                  <button
                    onClick={handleUndian}
                    disabled={publish.isPending}
                    className="w-full py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
                  >
                    Group Draw (match day)
                  </button>
                </div>
              </div>
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
          <TeamGroupSchedule
            teams={teams}
            matches={matches}
            saving={publish.isPending}
            overlays={overlays}
            partaiPhotos={schedulePartaiPhotos}
            postModeMatches={schedulePostModeMatches}
            onChangePartai={(matchIdx, pi, patch) => updatePartai(matchIdx, pi, patch)}
            onUpdateCourt={updateCourt}
            dirtyByMatchId={dirtyByMatchId}
            onSave={() => localMatches && saveMatches(localMatches)}
            onDraw={handleUndian}
            onSetPartaiPhoto={(key, img) => setSchedulePartaiPhotos((prev) => ({ ...prev, [key]: img }))}
            onSetPostMode={(matchId, on) => setSchedulePostModeMatches((prev) => ({ ...prev, [matchId]: on }))}
          />
        )}

        {tab === 'final' && (
          <>
            {finalMatch ? (
              <>
                {/* Champion banner */}
                {finalOutcome?.complete && championName && (
                  <div className="bg-linear-to-r from-accent/20 via-accent/10 to-accent/20 border border-accent/30 rounded-lg px-4 py-3 text-center">
                    <p className="text-[10px] text-accent uppercase tracking-widest mb-1">Champion</p>
                    <p className="text-lg font-bold text-fg">🏆 {championName}</p>
                    <p className="text-xs text-fg-dim mt-0.5">
                      {finalOutcome.aWins} - {finalOutcome.bWins}
                    </p>
                  </div>
                )}
                <TeamMatchCard
                  key={finalMatch.id}
                  match={finalMatch}
                  teams={teams}
                  saving={publish.isPending}
                  dirty={dirtyByMatchId[finalMatch.id] ?? false}
                  onChange={(_, pi, patch) => updatePartai((localMatches ?? snap.matches).findIndex((x) => x.id === finalMatch.id), pi, patch)}
                  onUpdateCourt={updateCourt}
                  matchIdx={(localMatches ?? snap.matches).findIndex((x) => x.id === finalMatch.id)}
                  onSave={() => localMatches && saveMatches(localMatches)}
                />

                {/* Export Posts section */}
                <div className="bg-surface border border-border-subtle rounded-lg px-4 py-3 flex flex-col gap-2">
                  <p className="text-xs text-fg-dim uppercase tracking-wider">Export Posts</p>

                  {PARTAI_CLASSES.map(([clsA, clsB], pi) => (
                    <div key={pi} className="flex items-center justify-between">
                      <span className="text-xs text-fg-dim">{clsA}{clsB} partai photo</span>
                      <div className="relative">
                        <button
                          onClick={() => { activeFinalKey.current = `partai-${pi}`; finalFileInputRef.current?.click() }}
                          className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center"
                          aria-label={`Upload ${clsA}${clsB} photo`}
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                            <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                            <circle cx="12" cy="13" r="4"/>
                          </svg>
                        </button>
                        {finalPhotos[`partai-${pi}`] && <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />}
                      </div>
                    </div>
                  ))}

                  {championName && (
                    <div className="flex items-center justify-between">
                      <span className="text-xs text-fg-dim">Champion photo</span>
                      <div className="relative">
                        <button
                          onClick={() => { activeFinalKey.current = 'champion'; finalFileInputRef.current?.click() }}
                          className="w-7 h-7 rounded-full bg-elevated border border-border-subtle flex items-center justify-center"
                          aria-label="Upload champion photo"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                            <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                            <circle cx="12" cy="13" r="4"/>
                          </svg>
                        </button>
                        {finalPhotos['champion'] && <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-surface" />}
                      </div>
                    </div>
                  )}

                  <div className="flex items-center justify-between pt-1 border-t border-border-subtle mt-1">
                    <span className="text-xs text-fg-dim">{Object.keys(finalPhotos).length} of {championName ? 4 : 3} photos</span>
                    <button
                      onClick={handleFinalDownload}
                      disabled={Object.keys(finalPhotos).length === 0}
                      className="w-8 h-8 rounded-full bg-accent flex items-center justify-center active:bg-yellow-300 disabled:opacity-40"
                      aria-label="Download final posts"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                        <polyline points="7 10 12 15 17 10"/>
                        <line x1="12" y1="15" x2="12" y2="3"/>
                      </svg>
                    </button>
                  </div>
                </div>

                <input
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  className="hidden"
                  ref={finalFileInputRef}
                  onChange={async (e) => {
                    const file = e.target.files?.[0]
                    const key = activeFinalKey.current
                    if (!file || !key) return
                    const url = URL.createObjectURL(file)
                    const img = new Image()
                    img.onload = () => { URL.revokeObjectURL(url); setFinalPhotos((prev) => ({ ...prev, [key]: img })) }
                    img.onerror = () => URL.revokeObjectURL(url)
                    img.src = url
                    e.target.value = ''
                  }}
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
