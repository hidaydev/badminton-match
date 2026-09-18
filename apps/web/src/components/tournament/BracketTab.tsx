import { Fragment, useState, useEffect } from 'react'
import { drawMatchPost, drawBracketRoundCover, drawPositionPost } from '../../utils/canvasPost'
import type { TournamentMatch, TournamentPair } from '../../utils/tournament'
import { QF_IDS, SF_IDS, FINAL_ID, THIRD_PLACE_ID } from '../../utils/tournament'
import { canvasToBlob, shareOrDownload } from '../../utils/share'
import { loadOverlayImages } from '../../utils/overlays'
import { useImageUploadMap } from '../../hooks/useImageUploadMap'
import Icon from '../Icon'
import ScoreModal from './ScoreModal'

interface BracketTabProps {
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
              <Icon name="camera" size={13} stroke="white" strokeWidth={2.2} />
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
            <div className="text-[9px] text-slate-400 text-center my-1">vs</div>
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

export default function BracketTab({ pairs, matches, onSetMatchScore, onOpenModal, isFetching, refetch }: BracketTabProps) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const [postModeRounds, setPostModeRounds] = useState<Record<string, boolean>>({})
  const { images: bracketPhotos, fileInputRef: bracketFileInputRef, openUpload: openBracketUpload, onFileChange: onBracketFileChange } = useImageUploadMap()
  const [overlays, setOverlays] = useState<{
    logo?: HTMLImageElement
    badge?: HTMLImageElement
    chevrons?: HTMLImageElement
    sponsor?: HTMLImageElement
    summaryBg?: HTMLImageElement
  }>({})
  const { images: podiumPhotos, fileInputRef: podiumFileInputRef, openUpload: openPodiumUpload, onFileChange: onPodiumFileChange } = useImageUploadMap()

  useEffect(() => {
    loadOverlayImages({
      logo: '/instagram-logo.png',
      badge: '/tournament-badge.png',
      chevrons: '/chevrons.png',
      sponsor: '/sponsor-logo.png',
      summaryBg: '/summary-bg.png',
    }).then(setOverlays)
  }, [])

  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null

  const handleSelect = (match: TournamentMatch) => {
    onOpenModal()
    setActiveMatchId(match.id)
  }

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'
  const get = (id: string) => matches.find((m) => m.id === id)

  const [qf1, qf2, qf3, qf4] = QF_IDS.map(get)
  const [sf1, sf2] = SF_IDS.map(get)
  const final = get(FINAL_ID); const third = get(THIRD_PLACE_ID)

  // Round config header — satu blok JSX di-map dari sini (QF/SF/Final).
  const rounds: {
    id: string
    title: string
    ariaLabel: string
    downloadTitle: string
    matchIds: readonly string[]
  }[] = [
    { id: 'qf', title: 'QF', ariaLabel: 'Download QF posts', downloadTitle: 'QUARTERFINAL', matchIds: QF_IDS },
    { id: 'sf', title: 'SF', ariaLabel: 'Download SF posts', downloadTitle: 'SEMIFINAL', matchIds: SF_IDS },
    { id: 'final', title: 'Final', ariaLabel: 'Download Final posts', downloadTitle: 'FINAL', matchIds: [FINAL_ID, THIRD_PLACE_ID] },
  ]

  /** Factory handler upload foto per match — hindari 8 closure inline identik. */
  const openUpload = (matchId: string) => () => openBracketUpload(matchId)

  if (!qf1) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="text-slate-400"><path d="M8 21h8M12 17v4M7 4h10v4a5 5 0 0 1-10 0V4z"/><path d="M7 6H3v2a3 3 0 0 0 4 2.8M17 6h4v2a3 3 0 0 1-4 2.8"/></svg>
        <p className="text-slate-400 text-sm">Assign groups and confirm to see the bracket.</p>
      </div>
    )
  }

  const winner = (m?: TournamentMatch) =>
    m?.scoreA != null && m?.scoreB != null
      ? getPairName(m.scoreA > m.scoreB ? m.pairAId : m.pairBId)
      : null
  const loser = (m?: TournamentMatch) =>
    m?.scoreA != null && m?.scoreB != null
      ? getPairName(m.scoreA < m.scoreB ? m.pairAId : m.pairBId)
      : null

  const bracketSubtitle = (matchId: string): string => {
    const map: Record<string, string> = {
      [QF_IDS[0]]: 'QUARTERFINAL · QF 1',
      [QF_IDS[1]]: 'QUARTERFINAL · QF 2',
      [QF_IDS[2]]: 'QUARTERFINAL · QF 3',
      [QF_IDS[3]]: 'QUARTERFINAL · QF 4',
      [SF_IDS[0]]: 'SEMIFINAL · SF 1',
      [SF_IDS[1]]: 'SEMIFINAL · SF 2',
      [FINAL_ID]: 'FINAL',
      [THIRD_PLACE_ID]: '3RD PLACE',
    }
    return map[matchId] ?? matchId.toUpperCase()
  }

  const handleDownloadPosition = async (pos: string, positionLabel: string, name: string) => {
    const photo = podiumPhotos[pos]
    if (!photo) return
    const c = document.createElement('canvas')
    drawPositionPost({ canvas: c, photo, positionLabel, name, logo: overlays.logo, chevrons: overlays.chevrons, sponsor: overlays.sponsor, badge: overlays.badge })
    const blob = await canvasToBlob(c)
    if (!blob) return
    const file = new File([blob], `bracket-${pos}.jpg`, { type: 'image/jpeg' })
    await shareOrDownload([file], positionLabel)
  }

  const handleDownloadRound = async (roundMatchIds: readonly string[], roundTitle: string) => {
    const roundSlug = roundTitle.toLowerCase().replace(/\s+/g, '-')
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
    drawBracketRoundCover({ canvas: coverCanvas, roundTitle, matchRows: coverRows, summaryBg: overlays.summaryBg, logo: overlays.logo, sponsor: overlays.sponsor })
    const coverBlob = await canvasToBlob(coverCanvas)
    if (coverBlob) files.push(new File([coverBlob], `bracket-${roundSlug}-cover.jpg`, { type: 'image/jpeg' }))

    // Per-match photo posts
    for (const id of roundMatchIds) {
      const photo = bracketPhotos[id]
      const match = matches.find(m => m.id === id)
      if (!photo || !match) continue
      const c = document.createElement('canvas')
      drawMatchPost({
        canvas: c,
        photo,
        pairAName: getPairName(match.pairAId),
        pairBName: getPairName(match.pairBId),
        scoreA: match.scoreA,
        scoreB: match.scoreB,
        subtitle: bracketSubtitle(id),
        logo: overlays.logo,
        badge: overlays.badge,
        chevrons: overlays.chevrons,
        sponsor: overlays.sponsor,
      })
      const blob = await canvasToBlob(c)
      if (blob) files.push(new File([blob], `bracket-${id}.jpg`, { type: 'image/jpeg' }))
    }

    if (files.length === 0) return
    await shareOrDownload(files, 'Bracket Photos')
  }

  return (
    <div>
      {/* Bracket — horizontally scrollable */}
      <div className="overflow-x-auto -mx-3 px-3 pb-2">
        <div className="min-w-75 w-full">
          {/* Column headers */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] mb-2 text-[10px] text-slate-400 uppercase tracking-widest font-semibold">
            {rounds.map((round, i) => (
              <Fragment key={round.id}>
                {i > 0 && <span />}
                <div className="flex items-center justify-center gap-1.5">
                  <span>{round.title}</span>
                  <button
                    onClick={() => setPostModeRounds(prev => ({ ...prev, [round.id]: !prev[round.id] }))}
                    className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${postModeRounds[round.id] ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
                  >
                    <Icon name="camera" size={15} stroke={postModeRounds[round.id] ? 'black' : 'white'} strokeWidth={2.2} />
                  </button>
                  {postModeRounds[round.id] && round.matchIds.some(id => bracketPhotos[id]) && (
                    <button
                      aria-label={round.ariaLabel}
                      onClick={() => handleDownloadRound(round.matchIds, round.downloadTitle)}
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
              </Fragment>
            ))}
          </div>

          {/* Upper half: QF1+QF2 → SF1 → Final */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center mb-3">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf1} label="QF 1 · A1 vs B2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos[QF_IDS[0]]} onUploadPhoto={openUpload(QF_IDS[0])} />
              <MatchCard match={qf2} label="QF 2 · C2 vs D1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos[QF_IDS[1]]} onUploadPhoto={openUpload(QF_IDS[1])} />
            </div>
            <Connector />
            <MatchCard match={sf1} label="SEMI 1" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos[SF_IDS[0]]} onUploadPhoto={openUpload(SF_IDS[0])} />
            <Connector />
            <MatchCard match={final} label="FINAL" borderColor="border-yellow-500" labelColor="text-yellow-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos[FINAL_ID]} onUploadPhoto={openUpload(FINAL_ID)} />
          </div>

          {/* Lower half: QF3+QF4 → SF2 | 3RD PLACE (no connector) */}
          <div className="grid grid-cols-[1fr_10px_1fr_10px_1fr] items-center">
            <div className="flex flex-col gap-3">
              <MatchCard match={qf3} label="QF 3 · C1 vs D2" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos[QF_IDS[2]]} onUploadPhoto={openUpload(QF_IDS[2])} />
              <MatchCard match={qf4} label="QF 4 · A2 vs B1" borderColor="border-sky-500" labelColor="text-sky-400" getPairName={getPairName} onSelect={handleSelect}
                showPostIcon={postModeRounds.qf} hasPhoto={!!bracketPhotos[QF_IDS[3]]} onUploadPhoto={openUpload(QF_IDS[3])} />
            </div>
            <Connector />
            <MatchCard match={sf2} label="SEMI 2" borderColor="border-violet-500" labelColor="text-violet-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.sf} hasPhoto={!!bracketPhotos[SF_IDS[1]]} onUploadPhoto={openUpload(SF_IDS[1])} />
            <span /> {/* no connector to 3rd place */}
            <MatchCard match={third} label="3RD" borderColor="border-slate-600" labelColor="text-slate-400" getPairName={getPairName} onSelect={handleSelect}
              showPostIcon={postModeRounds.final} hasPhoto={!!bracketPhotos[THIRD_PLACE_ID]} onUploadPhoto={openUpload(THIRD_PLACE_ID)} />
          </div>
        </div>
      </div>

      {/* Podium — full width, outside horizontal scroll */}
      {(() => {
        const championName = winner(final) ?? 'TBD'
        const runnerUpName = loser(final) ?? 'TBD'
        const thirdName = winner(third) ?? 'TBD'
        const positions = [
          { pos: 'runner-up', rank: '2', rankCls: 'text-slate-300', label: '2nd', positionLabel: 'RUNNER UP', name: runnerUpName, mt: '', champion: false },
          { pos: 'champion', rank: '1', rankCls: 'text-accent', label: 'CHAMPION', positionLabel: 'WINNER', name: championName, mt: '-mt-4', champion: true },
          { pos: 'third', rank: '3', rankCls: 'text-slate-400', label: '3rd', positionLabel: '3RD PLACE', name: thirdName, mt: '', champion: false },
        ]
        return (
          <div className="mt-5 bg-slate-800 rounded-lg p-4 flex justify-around items-end">
              {positions.map(({ pos, rank, rankCls, label, positionLabel, name, mt, champion: isChamp }) => (
                <div key={pos} className={`text-center ${mt}`}>
                  <div className={`${isChamp ? 'text-3xl' : 'text-2xl'} font-bold font-sans ${rankCls}`}>{rank}</div>
                  <div className={`text-[10px] mt-1 font-bold ${isChamp ? 'text-accent' : 'text-slate-400'}`}>{label}</div>
                  <div className={`text-xs mt-1 font-medium ${isChamp ? 'text-slate-200 text-sm' : 'text-slate-300'}`}>{name}</div>
                  <div className="mt-2 flex items-center justify-center gap-1.5">
                    <button
                      onClick={() => openPodiumUpload(pos)}
                      className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${podiumPhotos[pos] ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'}`}
                    >
                      <Icon name="camera" size={15} stroke={podiumPhotos[pos] ? 'black' : 'white'} strokeWidth={2.2} />
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
                </div>
              ))}
          </div>
        )
      })()}

      {activeMatch && (
        <ScoreModal
          key={`${activeMatch.id}:${activeMatch.scoreA ?? 'na'}:${activeMatch.scoreB ?? 'na'}:${isFetching ? 'loading' : 'ready'}`}
          match={activeMatch}
          pairAName={getPairName(activeMatch.pairAId)}
          pairBName={getPairName(activeMatch.pairBId)}
          onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatchId(null) }}
          onClose={() => setActiveMatchId(null)}
          isFetching={isFetching}
          refetch={refetch}
        />
      )}
      <input ref={bracketFileInputRef} type="file" accept="image/*" className="hidden" onChange={onBracketFileChange} />
      <input ref={podiumFileInputRef} type="file" accept="image/*" className="hidden" onChange={onPodiumFileChange} />
    </div>
  )
}
