import { useState, useRef, useEffect } from 'react'
import { computeGroupStandings, GROUP_COURTS } from '../../utils/tournament'
import type { GroupId, TournamentMatch, TournamentPair, StandingRow } from '../../utils/tournament'
import ScoreModal from './ScoreModal'
import { loadImage, drawCoverFill, drawHeader } from '../../utils/canvasPost'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

interface Props {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onResetGroups: () => void
  onRegeneratePics: () => void
  isRegeneratingPics: boolean
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}

function drawMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  pairAName: string,
  pairBName: string,
  scoreA: number,
  scoreB: number,
  groupId: string,
  matchIndex: number,
  logo: HTMLImageElement | undefined,
  badge: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Layer 1: photo
  drawCoverFill(ctx, photo, W, H, 0, 0, 1)

  // Layer 2: chevrons ornament (right pointing right, left rotated up)
  if (chevrons) {
    const h = 115
    const w = h * (chevrons.naturalWidth / chevrons.naturalHeight)
    ctx.drawImage(chevrons, W - w - 30, H * 0.3, w, h)
    ctx.save()
    const lcx = 30 + w / 2
    const lcy = H * 0.3 + h / 2
    ctx.translate(lcx, lcy)
    ctx.rotate(-Math.PI / 4)
    ctx.drawImage(chevrons, -w / 2, -h / 2, w, h)
    ctx.restore()
  }

  // Layer 3: header
  drawHeader(ctx, W, logo)

  // Layer 3: score footer
  const footerH = 160
  const footerY = H - footerH
  ctx.save()
  ctx.fillStyle = 'rgba(0,0,0,0.82)'
  ctx.fillRect(0, footerY, W, footerH)
  ctx.restore()

  // Pair names + score row
  const scoreY = footerY + 58
  ctx.save()
  ctx.font = 'bold 42px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'left'
  const maxNameW = 340
  let nameA = pairAName
  while (ctx.measureText(nameA).width > maxNameW && nameA.length > 1) nameA = nameA.slice(0, -1)
  if (nameA !== pairAName) nameA += '…'
  ctx.fillText(nameA, 60, scoreY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 42px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'right'
  let nameB = pairBName
  while (ctx.measureText(nameB).width > maxNameW && nameB.length > 1) nameB = nameB.slice(0, -1)
  if (nameB !== pairBName) nameB += '…'
  ctx.fillText(nameB, W - 60, scoreY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 56px monospace'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'center'
  ctx.fillText(`${scoreA} – ${scoreB}`, W / 2, scoreY)
  ctx.restore()

  // Badge — large, low opacity, right side (like Tournament card on home page)
  if (badge) {
    const badgeH = 150
    const badgeW = badgeH * (badge.naturalWidth / badge.naturalHeight)
    ctx.save()
    ctx.globalAlpha = 0.18
    ctx.drawImage(badge, W - badgeW + 20, footerY + (footerH - badgeH) / 2, badgeW, badgeH)
    ctx.restore()
  }

  // Subtitle
  ctx.save()
  ctx.font = '28px monospace'
  ctx.fillStyle = '#64748b'
  ctx.textAlign = 'center'
  ctx.fillText(`GROUP ${groupId} · MATCH ${matchIndex}`, W / 2, footerY + 105)
  ctx.restore()
}

function drawGroupSummary(
  canvas: HTMLCanvasElement,
  groupId: string,
  standings: StandingRow[],
  getPairName: (id: string | null) => string,
  storyBg: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Background
  if (storyBg) {
    ctx.drawImage(storyBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#f59e0b'
    ctx.fillRect(0, 0, W, H)
  }

  // Dark card
  const CARD_X = 80
  const CARD_W = W - CARD_X * 2
  const ROW_H = 110
  const ROW_GAP = 10
  const CARD_PAD_TOP = 70
  const TITLE_H = 130
  const HDR_H = 50
  const CARD_PAD_BOT = 50
  const CARD_H = CARD_PAD_TOP + TITLE_H + HDR_H + standings.length * (ROW_H + ROW_GAP) + CARD_PAD_BOT
  const CARD_Y = (H - CARD_H) / 2

  ctx.save()
  ctx.fillStyle = 'rgba(4,7,14,0.94)'
  ctx.beginPath()
  ctx.roundRect(CARD_X, CARD_Y, CARD_W, CARD_H, 32)
  ctx.fill()
  ctx.restore()

  // Title
  const INNER_X = CARD_X + 60
  ctx.save()
  ctx.font = '28px monospace'
  ctx.fillStyle = '#64748b'
  ctx.letterSpacing = '4px'
  ctx.textAlign = 'left'
  ctx.fillText('FINAL STANDINGS', INNER_X, CARD_Y + CARD_PAD_TOP + 36)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 72px Arial, sans-serif'
  ctx.fillStyle = '#facc15'
  ctx.letterSpacing = '2px'
  ctx.textAlign = 'left'
  ctx.fillText(`GROUP ${groupId}`, INNER_X, CARD_Y + CARD_PAD_TOP + 120)
  ctx.restore()

  // Column header
  const HDR_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + 30
  const RIGHT_X = CARD_X + CARD_W - 60
  const DIFF_X = RIGHT_X - 120
  const L_X = DIFF_X - 90
  const W_X = L_X - 90
  const DOT_X = RIGHT_X

  ctx.save()
  ctx.font = 'bold 26px monospace'
  ctx.fillStyle = '#475569'
  ctx.textAlign = 'center'; ctx.fillText('W', W_X, HDR_Y)
  ctx.textAlign = 'center'; ctx.fillText('L', L_X, HDR_Y)
  ctx.textAlign = 'right';  ctx.fillText('+/-', DIFF_X, HDR_Y)
  ctx.restore()

  // Rows
  const ROWS_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + HDR_H

  standings.forEach((row, i) => {
    const rowY = ROWS_Y + i * (ROW_H + ROW_GAP)
    const baseline = rowY + ROW_H * 0.65
    const isAdvancing = i < 2

    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = 'rgba(250,204,21,0.07)'
      ctx.beginPath()
      ctx.roundRect(CARD_X + 16, rowY, CARD_W - 32, ROW_H, 16)
      ctx.fill()
      ctx.restore()
    }

    // Rank
    ctx.save()
    ctx.font = 'bold 44px Arial, sans-serif'
    ctx.fillStyle = isAdvancing ? '#facc15' : '#475569'
    ctx.textAlign = 'center'
    ctx.fillText(String(i + 1), INNER_X - 10, baseline)
    ctx.restore()

    // Name
    ctx.save()
    ctx.font = 'bold 40px Arial, sans-serif'
    ctx.fillStyle = isAdvancing ? '#fef08a' : '#64748b'
    ctx.textAlign = 'left'
    const nameX = INNER_X + 50
    const maxW = W_X - nameX - 40
    let name = getPairName(row.pairId)
    while (ctx.measureText(name).width > maxW && name.length > 1) name = name.slice(0, -1)
    if (name !== getPairName(row.pairId)) name += '…'
    ctx.fillText(name, nameX, baseline)
    ctx.restore()

    // W
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? '#e2e8f0' : '#64748b'
    ctx.textAlign = 'center'
    ctx.fillText(String(row.wins), W_X, baseline)
    ctx.restore()

    // L
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? '#e2e8f0' : '#64748b'
    ctx.textAlign = 'center'
    ctx.fillText(String(row.losses), L_X, baseline)
    ctx.restore()

    // +/-
    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = row.pointDiff > 0 ? '#4ade80' : row.pointDiff < 0 ? '#f87171' : '#475569'
    ctx.textAlign = 'right'
    ctx.fillText(row.pointDiff > 0 ? `+${row.pointDiff}` : row.pointDiff === 0 ? '—' : String(row.pointDiff), DIFF_X, baseline)
    ctx.restore()

    // Yellow dot for top 2
    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = '#facc15'
      ctx.beginPath()
      ctx.arc(DOT_X, rowY + ROW_H / 2, 8, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()
    }
  })
}

export default function GroupMatches({ pairs, groups, matches, onSetMatchScore, onResetGroups, onRegeneratePics, isRegeneratingPics, onOpenModal, isFetching, refetch }: Props) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null
  const [postModeGroups, setPostModeGroups] = useState<Record<string, boolean>>({})
  const [matchPhotos, setMatchPhotos] = useState<Record<string, HTMLImageElement>>({})
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const activeUploadMatchId = useRef<string | null>(null)

  const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; badge?: HTMLImageElement; storyBg?: HTMLImageElement; chevrons?: HTMLImageElement }>({})

  useEffect(() => {
    const load = async () => {
      const result: { logo?: HTMLImageElement; badge?: HTMLImageElement; storyBg?: HTMLImageElement; chevrons?: HTMLImageElement } = {}
      try { result.logo = await loadImage('/instagram-logo.png') } catch { /* skip */ }
      try { result.badge = await loadImage('/tournament-badge.png') } catch { /* skip */ }
      try { result.storyBg = await loadImage('/story-bg.png') } catch { /* skip */ }
      try { result.chevrons = await loadImage('/chevrons.png') } catch { /* skip */ }
      setOverlays(result)
    }
    load()
  }, [])

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'

  const handleDownloadGroup = async (
    g: GroupId,
    groupMatches: TournamentMatch[],
    pairIds: string[],
    allMatches: TournamentMatch[],
  ) => {
    const suffix = Math.floor(Math.random() * 90000) + 10000
    const triggerDownload = (blob: Blob, filename: string) => new Promise<void>(resolve => {
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      setTimeout(() => { URL.revokeObjectURL(url); resolve() }, 300)
    })

    const blobOf = (c: HTMLCanvasElement) => new Promise<Blob | null>(res => c.toBlob(res, 'image/jpeg', 0.92))

    // Generate match posts for matches with photos
    let matchIndex = 1
    for (const m of groupMatches) {
      const photo = matchPhotos[m.id]
      if (!photo || m.scoreA === null || m.scoreB === null) { matchIndex++; continue }
      const matchCanvas = document.createElement('canvas')
      drawMatchPost(
        matchCanvas,
        photo,
        getPairName(m.pairAId),
        getPairName(m.pairBId),
        m.scoreA,
        m.scoreB,
        g,
        matchIndex,
        overlays.logo,
        overlays.badge,
        overlays.chevrons,
      )
      const matchBlob = await blobOf(matchCanvas)
      if (matchBlob) await triggerDownload(matchBlob, `group-${g.toLowerCase()}-match-${matchIndex}-${suffix}.jpg`)
      matchIndex++
    }

    // Generate group summary
    const standings = computeGroupStandings(g, pairIds, allMatches)
    const summaryCanvas = document.createElement('canvas')
    drawGroupSummary(summaryCanvas, g, standings, getPairName, overlays.storyBg)
    const summaryBlob = await blobOf(summaryCanvas)
    if (summaryBlob) await triggerDownload(summaryBlob, `group-${g.toLowerCase()}-summary-${suffix}.jpg`)
  }

  return (
    <div className="space-y-4">
      <div className="flex justify-end gap-3">
        <button
          onClick={() => {
            if (confirm('Reassign scoring PICs? Current assignments will be replaced.')) onRegeneratePics()
          }}
          disabled={isRegeneratingPics}
          className="text-xs text-slate-500 hover:text-slate-300 underline disabled:opacity-50"
        >
          {isRegeneratingPics ? 'Regenerating…' : 'Regenerate PICs'}
        </button>
        <button
          onClick={() => {
            if (confirm('Reset group assignment? All scores will be lost.')) onResetGroups()
          }}
          className="text-xs text-slate-500 hover:text-slate-300 underline"
        >
          Reset groups
        </button>
      </div>

      {GROUP_IDS.map((g) => {
        const groupMatches = matches.filter((m) => m.phase === 'group' && m.groupId === g)
        const standings = computeGroupStandings(g, groups[g], matches)

        return (
          <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
            {/* Group header */}
            <div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
              <span className="text-yellow-300 font-bold text-sm">GROUP {g}</span>
              <div className="flex items-center gap-3">
                <span className="text-yellow-600 text-xs">Court {GROUP_COURTS[g]}</span>
                <button
                  onClick={() => setPostModeGroups(prev => ({ ...prev, [g]: !prev[g] }))}
                  className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors ${
                    postModeGroups[g] ? 'bg-yellow-400 active:bg-yellow-300' : 'bg-black/50 active:bg-black/70'
                  }`}
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke={postModeGroups[g] ? 'black' : 'white'} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                    <circle cx="12" cy="13" r="4"/>
                  </svg>
                </button>
              </div>
            </div>

            {/* Match rows */}
            <div className="divide-y divide-slate-700/50">
              {groupMatches.map((m) => (
                <div key={m.id} className="relative flex items-center divide-y-0">
                  <button
                    onClick={() => { onOpenModal(); setActiveMatchId(m.id) }}
                    className="flex-1 flex flex-col px-4 pt-3 pb-2.5 hover:bg-slate-700/50 active:bg-slate-600/60 active:scale-[0.98] transition-transform duration-75 gap-1.5"
                  >
                    <div className="flex items-center gap-2 w-full">
                      <span className="text-xs text-slate-300 flex-1 truncate text-left">{getPairName(m.pairAId)}</span>
                      <span className="text-xs font-bold text-yellow-400 shrink-0 min-w-[56px] text-center bg-slate-900 rounded-md px-2 py-1">
                        {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
                      </span>
                      <span className="text-xs text-slate-300 flex-1 text-right truncate">{getPairName(m.pairBId)}</span>
                    </div>
                    {m.picName && (
                      <span className="text-[9px] text-slate-500 leading-none text-center w-full">{m.picName}</span>
                    )}
                  </button>

                  {postModeGroups[g] && (
                    <div className="relative pr-3 shrink-0">
                      <button
                        aria-label={`Upload photo for match ${getPairName(m.pairAId)} vs ${getPairName(m.pairBId)}`}
                        onClick={() => {
                          activeUploadMatchId.current = m.id
                          fileInputRef.current?.click()
                        }}
                        className="w-7 h-7 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
                      >
                        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                          <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                          <circle cx="12" cy="13" r="4"/>
                        </svg>
                      </button>
                      {matchPhotos[m.id] && (
                        <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-green-500 border border-slate-800" />
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* Download bar */}
            {postModeGroups[g] && (
              <div className="px-4 py-2.5 flex items-center justify-between bg-slate-900/50 border-t border-slate-700">
                <span className="text-xs text-slate-500">
                  {Object.keys(matchPhotos).filter(id => groupMatches.some(m => m.id === id)).length} of {groupMatches.length} photos
                </span>
                <button
                  aria-label={`Download posts for Group ${g}`}
                  onClick={() => handleDownloadGroup(g, groupMatches, groups[g], matches)}
                  className="w-8 h-8 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                    <polyline points="7 10 12 15 17 10"/>
                    <line x1="12" y1="15" x2="12" y2="3"/>
                  </svg>
                </button>
              </div>
            )}

            {/* Mini standings */}
            <div className="border-t border-slate-700 px-4 py-2">
              <div className="grid grid-cols-[1.5rem_1fr_1.5rem_1.5rem_2.5rem_0.75rem] text-[10px] text-slate-600 mb-1 px-1 gap-x-2">
                <span>#</span><span></span>
                <span className="text-center">W</span>
                <span className="text-center">L</span>
                <span className="text-center">+/-</span>
                <span></span>
              </div>
              {standings.map((row, i) => (
                <div
                  key={row.pairId}
                  className={`grid grid-cols-[1.5rem_1fr_1.5rem_1.5rem_2.5rem_0.75rem] items-center py-1 px-1 rounded gap-x-2 text-xs ${i < 2 ? 'bg-yellow-400/[0.06]' : ''}`}
                >
                  <span className={`font-bold ${i < 2 ? 'text-yellow-100' : 'text-slate-600'}`}>{i + 1}</span>
                  <span className={`truncate font-medium ${i < 2 ? 'text-yellow-100' : 'text-slate-400'}`}>{getPairName(row.pairId)}</span>
                  <span className={`text-center ${i < 2 ? 'text-slate-300' : 'text-slate-500'}`}>{row.wins}</span>
                  <span className={`text-center ${i < 2 ? 'text-slate-300' : 'text-slate-500'}`}>{row.losses}</span>
                  <span className={`text-center font-medium ${row.pointDiff > 0 ? 'text-green-400' : row.pointDiff < 0 ? 'text-red-400' : 'text-slate-500'}`}>
                    {row.pointDiff > 0 ? `+${row.pointDiff}` : row.pointDiff === 0 ? '—' : row.pointDiff}
                  </span>
                  <span className={`w-1.5 h-1.5 rounded-full mx-auto ${i < 2 ? 'bg-yellow-400' : ''}`} />
                </div>
              ))}
            </div>
          </div>
        )
      })}

      <input
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        ref={fileInputRef}
        onChange={async (e) => {
          const file = e.target.files?.[0]
          const matchId = activeUploadMatchId.current
          if (!file || !matchId) return
          const url = URL.createObjectURL(file)
          const img = new Image()
          img.onload = () => {
            URL.revokeObjectURL(url)
            setMatchPhotos(prev => ({ ...prev, [matchId]: img }))
          }
          img.onerror = () => URL.revokeObjectURL(url)
          img.src = url
          e.target.value = ''
        }}
      />

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
    </div>
  )
}
