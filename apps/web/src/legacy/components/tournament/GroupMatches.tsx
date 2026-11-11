import { useState, useEffect } from 'react'
import { computeGroupStandings, GROUP_IDS } from '../../utils/tournament'
import { GROUP_COURTS } from '../../config/tournament'
import type { GroupId, TournamentMatch, TournamentPair } from '../../utils/tournament'
import { useImageUploadMap } from '../../hooks/useImageUploadMap'
import Icon from '../Icon'
import { hit44 } from '../hitTarget'
import ScoreModal from './ScoreModal'
import { drawMatchPost, drawGroupSummary } from '../../utils/canvasPost'
import { canvasToBlob, shareOrDownload } from '../../utils/share'
import { loadOverlayImages } from '../../utils/overlays'
import { t } from '../../../i18n'
import { StandingsTable } from '../../../components/StandingsTable'

interface GroupMatchesProps {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  canEdit: boolean
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}

export default function GroupMatches({ pairs, groups, matches, canEdit, onSetMatchScore, onOpenModal, isFetching, refetch }: GroupMatchesProps) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null
  const [postModeGroups, setPostModeGroups] = useState<Record<string, boolean>>({})
  const { images: matchPhotos, fileInputRef: matchFileInputRef, openUpload: openMatchUpload, onFileChange: onMatchFileChange } = useImageUploadMap()

  const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; badge?: HTMLImageElement; storyBg?: HTMLImageElement; summaryBg?: HTMLImageElement; chevrons?: HTMLImageElement; sponsor?: HTMLImageElement }>({})
  const [overlayError, setOverlayError] = useState(false)

  useEffect(() => {
    let active = true
    loadOverlayImages({
      logo: '/instagram-logo.png',
      badge: '/tournament-badge.png',
      storyBg: '/story-bg.png',
      summaryBg: '/summary-bg.png',
      chevrons: '/chevrons.png',
      sponsor: '/sponsor-logo.png',
    })
      .then((loaded) => {
        if (active) setOverlays(loaded)
      })
      .catch(() => {
        // A missing file leaves the overlays empty: the post still exports,
        // without its artwork. Say so instead of losing it silently.
        if (active) setOverlayError(true)
      })
    return () => {
      active = false
    }
  }, [])

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'

  const handleDownloadGroup = async (
    g: GroupId,
    groupMatches: TournamentMatch[],
    pairIds: string[],
    allMatches: TournamentMatch[],
  ) => {
    const groupSlug = `group-${g.toLowerCase()}`

    const files: File[] = []

    // Generate match posts for matches with photos
    let matchIndex = 1
    for (const m of groupMatches) {
      const photo = matchPhotos[m.id]
      if (!photo || m.scoreA === null || m.scoreB === null) { matchIndex++; continue }
      const matchCanvas = document.createElement('canvas')
      drawMatchPost({
        canvas: matchCanvas,
        photo,
        pairAName: getPairName(m.pairAId),
        pairBName: getPairName(m.pairBId),
        scoreA: m.scoreA,
        scoreB: m.scoreB,
        subtitle: `GROUP ${g} · MATCH ${matchIndex}`,
        logo: overlays.logo,
        badge: overlays.badge,
        chevrons: overlays.chevrons,
        sponsor: overlays.sponsor,
      })
      const matchBlob = await canvasToBlob(matchCanvas)
      if (matchBlob) files.push(new File([matchBlob], `${groupSlug}-match-${matchIndex}.jpg`, { type: 'image/jpeg' }))
      matchIndex++
    }

    // Generate group summary
    const standings = computeGroupStandings(g, pairIds, allMatches)
    const summaryCanvas = document.createElement('canvas')
    drawGroupSummary({ canvas: summaryCanvas, groupId: g, standings, getPairName, summaryBg: overlays.summaryBg, sponsor: overlays.sponsor, logo: overlays.logo })
    const summaryBlob = await canvasToBlob(summaryCanvas)
    if (summaryBlob) files.push(new File([summaryBlob], `${groupSlug}-summary.jpg`, { type: 'image/jpeg' }))

    if (files.length === 0) return
    await shareOrDownload(files, `Group ${g} Photos`)
  }

  return (
    <div className="space-y-4">
      {overlayError && (
        <p role="status" className="text-xs text-error">
          {t('tournament.error.overlays')}
        </p>
      )}
      {GROUP_IDS.map((g) => {
        const groupMatches = matches.filter((m) => m.phase === 'group' && m.groupId === g)
        const standings = computeGroupStandings(g, groups[g], matches)

        return (
          <div key={g} className="bg-surface rounded-xl overflow-hidden border border-border-subtle shadow-xs">
            {/* Group header */}
            <div className="px-4 py-2 flex justify-between items-center border-b border-border-subtle">
              <span className="text-accent font-bold text-sm">GROUP {g}</span>
              <div className="flex items-center gap-3">
                <span className="text-accent/80 text-xs">Court {GROUP_COURTS[g]}</span>
                <button
                  aria-label={`Photo mode for group ${g}`}
                  onClick={() => setPostModeGroups(prev => ({ ...prev, [g]: !prev[g] }))}
                  className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${hit44} ${
                    postModeGroups[g] ? 'bg-accent active:bg-accent/80' : 'bg-black/50 active:bg-black/70'
                  }`}
                >
                  <Icon name="camera" size={15} stroke={postModeGroups[g] ? 'black' : 'white'} strokeWidth={2.2} />
                </button>
              </div>
            </div>

            {/* Match rows */}
            <div className="divide-y divide-border-subtle">
              {groupMatches.map((m) => (
                <div key={m.id} className="relative flex items-center divide-y-0">
                  <button
                    onClick={() => { onOpenModal(); setActiveMatchId(m.id) }}
                    disabled={!canEdit}
                    className="flex-1 flex flex-col px-4 pt-3 pb-2.5 hover:bg-elevated/60 active:bg-elevated active:scale-98 transition-transform duration-75 gap-1.5 disabled:cursor-default disabled:hover:bg-transparent disabled:active:bg-transparent disabled:active:scale-100 hit44"
                  >
                    <div className="flex items-center gap-2 w-full">
                      <span className="text-xs text-fg flex-1 truncate text-left">{getPairName(m.pairAId)}</span>
                      <span className="text-xs font-bold font-mono text-accent shrink-0 min-w-14 text-center bg-elevated border border-border-subtle rounded-lg px-2 py-1">
                        {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
                      </span>
                      <span className="text-xs text-fg flex-1 text-right truncate">{getPairName(m.pairBId)}</span>
                    </div>
                    {m.picName && (
                      <span className="text-[11px] text-fg-dim leading-none text-center w-full">{m.picName}</span>
                    )}
                  </button>

                  {postModeGroups[g] && (
                    <div className="relative pl-2 pr-3 shrink-0">
                      <button
                        aria-label={`Upload photo for match ${getPairName(m.pairAId)} vs ${getPairName(m.pairBId)}`}
                        onClick={() => openMatchUpload(m.id)}
                        className={`w-7 h-7 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70 ${hit44}`}
                      >
                        <Icon name="camera" size={13} stroke="white" strokeWidth={2.2} />
                      </button>
                      {matchPhotos[m.id] && (
                        <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-success border border-surface" />
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* Download bar */}
            {postModeGroups[g] && (
              <div className="px-4 py-2.5 flex items-center justify-between bg-elevated/50 border-t border-border-subtle">
                <span className="text-xs text-fg-dim">
                  {Object.keys(matchPhotos).filter(id => groupMatches.some(m => m.id === id)).length} of {groupMatches.length} photos
                </span>
                <button
                  aria-label={`Download posts for Group ${g}`}
                  onClick={() => handleDownloadGroup(g, groupMatches, groups[g], matches)}
                  className={`w-8 h-8 rounded-full bg-accent flex items-center justify-center active:bg-accent/80 ${hit44}`}
                >
                  <Icon name="download-tray" size={15} stroke="black" />
                </button>
              </div>
            )}

            {/* Mini standings */}
            <div className="border-t border-border-subtle px-4 py-2">
              <StandingsTable
                layout="compact"
                labels={{ wins: 'W', losses: 'L' }}
                rows={standings.map((row, i) => ({
                  key: row.pairId,
                  name: getPairName(row.pairId),
                  wins: row.wins,
                  losses: row.losses,
                  diff: row.diff,
                  highlighted: i < 2,
                }))}
              />
            </div>
          </div>
        )
      })}

      <input
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        ref={matchFileInputRef}
        onChange={onMatchFileChange}
      />

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
    </div>
  )
}
