import { useState, useRef, useEffect } from 'react'
import { loadImage, drawMatchPost, drawBracketRoundCover, drawPositionPost } from '../../utils/canvasPost'
import type { TournamentMatch, TournamentPair } from '../../utils/tournament'
import ScoreModal from './ScoreModal'

interface Props {
  pairs: TournamentPair[]
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}

function MatchCard({
  match,
  label,
  borderColor,
  labelColor,
  getPairName,
  onSelect,
  showPostIcon,
  hasPhoto,
  onUploadPhoto,
}: {
  match?: TournamentMatch
  label: string
  borderColor: string
  labelColor: string
  getPairName: (id: string | null) => string
  onSelect: (match: TournamentMatch) => void
  showPostIcon?: boolean
  hasPhoto?: boolean
  onUploadPhoto?: () => void
}) {
  if (!match) return <div className="h-16 bg-slate-800/30 rounded-lg" />
  const canEnter = !!(match.pairAId && match.pairBId)
  const scored = match.scoreA !== null
  return (
    <div className={`w-full bg-slate-800 rounded-lg border-l-2 ${borderColor} overflow-hidden`}>
      <div className={`px-2 py-1.5 border-b border-slate-700 flex items-center justify-between`}>
        <span className={`text-[8px] font-bold tracking-wide ${labelColor}`}>{label}</span>
        {showPostIcon && (
          <div className="relative shrink-0">
            <button
              aria-label={`Upload photo for ${getPairName(match.pairAId)} vs ${getPairName(match.pairBId)}`}
              onClick={onUploadPhoto}
              className="w-7 h-7 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                <circle cx="12" cy="13" r="4"/>
              </svg>
            </button>
            {hasPhoto && (
              <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-slate-800" />
            )}
          </div>
        )}
      </div>
      <button
        onClick={() => canEnter && onSelect(match)}
        disabled={!canEnter}
        className="w-full text-left disabled:opacity-60 hover:bg-slate-700/50 disabled:hover:bg-transparent"
      >
        <div className="px-2 pt-2 pb-1">
          <div className="text-xs text-slate-200 font-medium truncate">{getPairName(match.pairAId)}</div>
          {scored ? (
            <div className="text-[10px] font-bold text-yellow-400 text-center my-1">{match.scoreA} – {match.scoreB}</div>
          ) : (
            <div className="text-[9px] text-slate-600 text-center my-1">vs</div>
          )}
          <div className="text-xs text-slate-200 font-medium truncate">{getPairName(match.pairBId)}</div>
        </div>
      </button>
    </div>
  )
}

function Connector() {
  return (
    <div className="flex items-stretch w-3 shrink-0">
      <div className="flex-1 border-t border-r border-b border-slate-700 rounded-r my-2" />
    </div>
  )
}

export default function BracketTab({ pairs, matches, onSetMatchScore, onOpenModal, isFetching, refetch }: Props) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const [postModeRounds, setPostModeRounds] = useState<Record<string, boolean>>({})
  const [bracketPhotos, setBracketPhotos] = useState<Record<string, HTMLImageElement>>({})
  const [overlays, setOverlays] = useState<{
    logo?: HTMLImageElement
    badge?: HTMLImageElement
    chevrons?: HTMLImageElement
    sponsor?: HTMLImageElement
    summaryBg?: HTMLImageElement
  }>({})
  const [podiumPhotos, setPodiumPhotos] = useState<Record<string, HTMLImageElement>>({})
  const activeUploadMatchId = useRef<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const podiumFileInputRef = useRef<HTMLInputElement>(null)
  const activePodiumPos = useRef<string | null>(null)

  useEffect(() => {
    const load = async () => {
      const result: typeof overlays = {}
      try { result.logo = await loadImage('/instagram-logo.png') } catch { /* skip */ }
      try { result.badge = await loadImage('/tournament-badge.png') } catch { /* skip */ }
      try { result.chevrons = await loadImage('/chevrons.png') } catch { /* skip */ }
      try { result.sponsor = await loadImage('/sponsor-logo.png') } catch { /* skip */ }
      try { result.summaryBg = await loadImage('/summary-bg.png') } catch { /* skip */ }
      setOverlays(result)
    }
    load()
  }, [])

  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null

  const handleSelect = (match: TournamentMatch) => {
    onOpenModal()
    setActiveMatchId(match.id)
  }

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'
  const get = (id: string) => matches.find((m) => m.id === id)

  const qf1 = get('qf-1'); const qf2 = get('qf-2')
  const qf3 = get('qf-3'); const qf4 = get('qf-4')
  const sf1 = get('sf-1'); const sf2 = get('sf-2')
  const final = get('final-1'); const third = get('3rd-1')

  if (!qf1) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <span className="text-4xl">🏆</span>
        <p className="text-slate-400 text-sm">Assign groups and confirm to see the bracket.</p>
      </div>
    )
  }

  const winner = (m?: TournamentMatch) =>
    m?.scoreA !== null && m?.scoreA !== undefined
      ? getPairName(m.scoreA > m.scoreB! ? m.pairAId : m.pairBId)
      : null
  const loser = (m?: TournamentMatch) =>
    m?.scoreA !== null && m?.scoreA !== undefined
      ? getPairName(m.scoreA < m.scoreB! ? m.pairAId : m.pairBId)
      : null

  const bracketSubtitle = (matchId: string): string => {
    const map: Record<string, string> = {
      'qf-1': 'QUARTERFINAL · QF 1',
      'qf-2': 'QUARTERFINAL · QF 2',
      'qf-3': 'QUARTERFINAL · QF 3',
      'qf-4': 'QUARTERFINAL · QF 4',
      'sf-1': 'SEMIFINAL · SF 1',
      'sf-2': 'SEMIFINAL · SF 2',
      'final-1': 'FINAL',
      '3rd-1': '3RD PLACE',
    }
    return map[matchId] ?? matchId.toUpperCase()
  }

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    const matchId = activeUploadMatchId.current
    if (!file || !matchId) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => { URL.revokeObjectURL(url); setBracketPhotos(prev => ({ ...prev, [matchId]: img })) }
    img.onerror = () => URL.revokeObjectURL(url)
    img.src = url
    e.target.value = ''
  }

  const handlePodiumFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    const pos = activePodiumPos.current
    if (!file || !pos) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => { URL.revokeObjectURL(url); setPodiumPhotos(prev => ({ ...prev, [pos]: img })) }
    img.onerror = () => URL.revokeObjectURL(url)
    img.src = url
    e.target.value = ''
  }

  const handleDownloadPosition = async (pos: string, positionLabel: string, name: string) => {
    const photo = podiumPhotos[pos]
    if (!photo) return
    const c = document.createElement('canvas')
    drawPositionPost(c, photo, positionLabel, name, overlays.logo, overlays.chevrons, overlays.sponsor)
    const suffix = Math.floor(Math.random() * 90000) + 10000
    const blob = await new Promise<Blob | null>(res => c.toBlob(res, 'image/jpeg', 0.92))
    if (!blob) return
    const file = new File([blob], `bracket-${pos}-${suffix}.jpg`, { type: 'image/jpeg' })
    const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
    if (isIOS && navigator.canShare?.({ files: [file] })) {
      await navigator.share({ files: [file], title: positionLabel })
    } else {
      const url = URL.createObjectURL(file)
      const a = document.createElement('a')
      a.href = url; a.download = file.name
      document.body.appendChild(a); a.click(); document.body.removeChild(a)
      setTimeout(() => URL.revokeObjectURL(url), 300)
    }
  }

  const handleDownloadRound = async (roundMatchIds: string[], roundTitle: string) => {
    const suffix = Math.floor(Math.random() * 90000) + 10000
    const blobOf = (c: HTMLCanvasElement) => new Promise<Blob | null>(res => c.toBlob(res, 'image/jpeg', 0.92))
    const files: File[] = []

    // Cover card — always included
    const coverRows = roundMatchIds.map(id => {
      const m = matches.find(x => x.id === id)
      return {
        label: bracketSubtitle(id),
        nameA: getPairName(m?.pairAId ?? null),
        nameB: getPairName(m?.pairBId ?? null),
        scoreA: m?.scoreA ?? null,
        scoreB: m?.scoreB ?? null,
      }
    })
    const coverCanvas = document.createElement('canvas')
    drawBracketRoundCover(coverCanvas, roundTitle, coverRows, overlays.summaryBg, overlays.logo, overlays.sponsor)
    const coverBlob = await blobOf(coverCanvas)
    if (coverBlob) files.push(new File([coverBlob], `bracket-${roundTitle.toLowerCase()}-cover-${suffix}.jpg`, { type: 'image/jpeg' }))

    // Per-match photo posts
    for (const id of roundMatchIds) {
      const photo = bracketPhotos[id]
      const match = matches.find(m => m.id === id)
      if (!photo || !match) continue
      const c = document.createElement('canvas')
      drawMatchPost(
        c,
        photo,
        getPairName(match.pairAId),
        getPairName(match.pairBId),
        match.scoreA,
        match.scoreB,
        bracketSubtitle(id),
        overlays.logo,
        overlays.badge,
        overlays.chevrons,
        overlays.sponsor,
      )
      const blob = await blobOf(c)
      if (blob) files.push(new File([blob], `bracket-${id}-${suffix}.jpg`, { type: 'image/jpeg' }))
    }

    if (files.length === 0) return

    const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
    if (isIOS && navigator.canShare?.({ files })) {
      await navigator.share({ files, title: 'Bracket Photos' })
    } else {
      for (const file of files) {
        const url = URL.createObjectURL(file)
        const a = document.createElement('a')
        a.href = url
        a.download = file.name
        document.body.appendChild(a)
        a.click()
        document.body.removeChild(a)
        await new Promise<void>(r => setTimeout(() => { URL.revokeObjectURL(url); r() }, 300))
      }
    }
  }

  return (
    <div>
      {/* Bracket — horizontally scrollable */}
      <div className="overflow-x-auto -mx-3 px-3 pb-2">
        <div className="min-w-[300px] w-full">
          {/* Column headers */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] mb-2 text-[10px] text-slate-400 uppercase tracking-widest font-semibold">
            {/* QF header */}
            <div className="flex items-center justify-center gap-1.5">
              <span>QF</span>
              <button
                onClick={() => setPostModeRounds(prev => ({ ...prev, qf: !prev.qf }))}
                className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${postModeRounds.qf ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.qf ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                  <circle cx="12" cy="13" r="4"/>
                </svg>
              </button>
              {postModeRounds.qf && ['qf-1','qf-2','qf-3','qf-4'].some(id => bracketPhotos[id]) && (
                <button
                  aria-label="Download QF posts"
                  onClick={() => handleDownloadRound(['qf-1','qf-2','qf-3','qf-4'], 'QUARTERFINAL')}
                  className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                    <polyline points="7 10 12 15 17 10"/>
                    <line x1="12" y1="15" x2="12" y2="3"/>
                  </svg>
                </button>
              )}
            </div>
            <span />
            {/* SF header */}
            <div className="flex items-center justify-center gap-1.5">
              <span>SF</span>
              <button
                onClick={() => setPostModeRounds(prev => ({ ...prev, sf: !prev.sf }))}
                className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${postModeRounds.sf ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.sf ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                  <circle cx="12" cy="13" r="4"/>
                </svg>
              </button>
              {postModeRounds.sf && ['sf-1','sf-2'].some(id => bracketPhotos[id]) && (
                <button
                  aria-label="Download SF posts"
                  onClick={() => handleDownloadRound(['sf-1','sf-2'], 'SEMIFINAL')}
                  className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                    <polyline points="7 10 12 15 17 10"/>
                    <line x1="12" y1="15" x2="12" y2="3"/>
                  </svg>
                </button>
              )}
            </div>
            <span />
            {/* Final header */}
            <div className="flex items-center justify-center gap-1.5">
              <span>Final</span>
              <button
                onClick={() => setPostModeRounds(prev => ({ ...prev, final: !prev.final }))}
                className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${postModeRounds.final ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={postModeRounds.final ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                  <circle cx="12" cy="13" r="4"/>
                </svg>
              </button>
              {postModeRounds.final && ['final-1','3rd-1'].some(id => bracketPhotos[id]) && (
                <button
                  aria-label="Download Final posts"
                  onClick={() => handleDownloadRound(['final-1','3rd-1'], 'FINAL')}
                  className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                    <polyline points="7 10 12 15 17 10"/>
                    <line x1="12" y1="15" x2="12" y2="3"/>
                  </svg>
                </button>
              )}
            </div>
          </div>

          {/* Upper half: QF1+QF2 → SF1 → Final */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center mb-3">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf1} label="QF 1 · A1 vs B2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-1'; fileInputRef.current?.click() }} />
              <MatchCard match={qf2} label="QF 2 · C2 vs D1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-2']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-2'; fileInputRef.current?.click() }} />
            </div>
            <Connector />
            <MatchCard match={sf1} label="SEMI 1" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos['sf-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'sf-1'; fileInputRef.current?.click() }} />
            <Connector />
            <MatchCard match={final} label="🏆 FINAL" borderColor="border-yellow-500" labelColor="text-yellow-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos['final-1']} onUploadPhoto={() => { activeUploadMatchId.current = 'final-1'; fileInputRef.current?.click() }} />
          </div>

          {/* Lower half: QF3+QF4 → SF2 | 3RD PLACE (no connector) */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf3} label="QF 3 · C1 vs D2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-3']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-3'; fileInputRef.current?.click() }} />
              <MatchCard match={qf4} label="QF 4 · A2 vs B1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos['qf-4']} onUploadPhoto={() => { activeUploadMatchId.current = 'qf-4'; fileInputRef.current?.click() }} />
            </div>
            <Connector />
            <MatchCard match={sf2} label="SEMI 2" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos['sf-2']} onUploadPhoto={() => { activeUploadMatchId.current = 'sf-2'; fileInputRef.current?.click() }} />
            <span /> {/* no connector to 3rd place */}
            <MatchCard match={third} label="🥉 3RD" borderColor="border-slate-600" labelColor="text-slate-500" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos['3rd-1']} onUploadPhoto={() => { activeUploadMatchId.current = '3rd-1'; fileInputRef.current?.click() }} />
          </div>
        </div>
      </div>

      {/* Podium — full width, outside horizontal scroll */}
      {(() => {
        const championName = winner(final) ?? 'TBD'
        const runnerUpName = loser(final) ?? 'TBD'
        const thirdName = winner(third) ?? 'TBD'
        const positions = [
          { pos: 'runner-up', emoji: '🥈', label: '2nd', positionLabel: 'RUNNER UP', name: runnerUpName, mt: '', champion: false },
          { pos: 'champion', emoji: '🏆', label: 'CHAMPION', positionLabel: '🏆  WINNER', name: championName, mt: '-mt-4', champion: true },
          { pos: 'third', emoji: '🥉', label: '3rd', positionLabel: '3RD PLACE', name: thirdName, mt: '', champion: false },
        ]
        return (
          <div className="mt-5 bg-slate-800 rounded-2xl overflow-hidden">
            <div className="p-4 flex justify-around items-end">
              {positions.map(({ pos, emoji, label, name, mt, champion: isChamp }) => (
                <div key={pos} className={`text-center ${mt}`}>
                  <div className={isChamp ? 'text-3xl' : 'text-2xl'}>{emoji}</div>
                  <div className={`text-[10px] mt-1 font-bold ${isChamp ? 'text-yellow-400' : 'text-slate-500'}`}>{label}</div>
                  <div className={`text-xs mt-1 font-medium ${isChamp ? 'text-yellow-200 text-sm' : 'text-slate-300'}`}>{name}</div>
                </div>
              ))}
            </div>
            <div className="border-t border-slate-700 flex divide-x divide-slate-700">
              {positions.map(({ pos, positionLabel, name }) => (
                <div key={pos} className="flex-1 flex items-center justify-center gap-2 py-2.5">
                  <button
                    onClick={() => { activePodiumPos.current = pos; podiumFileInputRef.current?.click() }}
                    className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${podiumPhotos[pos] ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={podiumPhotos[pos] ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                      <circle cx="12" cy="13" r="4"/>
                    </svg>
                  </button>
                  {podiumPhotos[pos] && (
                    <button
                      onClick={() => handleDownloadPosition(pos, positionLabel, name)}
                      className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                        <polyline points="7 10 12 15 17 10"/>
                        <line x1="12" y1="15" x2="12" y2="3"/>
                      </svg>
                    </button>
                  )}
                </div>
              ))}
            </div>
          </div>
        )
      })()}

      {activeMatch && (
        <ScoreModal
          match={activeMatch}
          pairAName={getPairName(activeMatch.pairAId)}
          pairBName={getPairName(activeMatch.pairBId)}
          onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatchId(null) }}
          onClose={() => setActiveMatchId(null)}
          isFetching={isFetching}
          refetch={refetch}
        />
      )}
      <input ref={fileInputRef} type="file" accept="image/*" className="hidden" onChange={handleFileChange} />
      <input ref={podiumFileInputRef} type="file" accept="image/*" className="hidden" onChange={handlePodiumFileChange} />
    </div>
  )
}
