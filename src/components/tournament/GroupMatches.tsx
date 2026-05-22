import { useState, useRef } from 'react'
import { computeGroupStandings, GROUP_COURTS } from '../../utils/tournament'
import type { GroupId, TournamentMatch, TournamentPair } from '../../utils/tournament'
import ScoreModal from './ScoreModal'

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

export default function GroupMatches({ pairs, groups, matches, onSetMatchScore, onResetGroups, onRegeneratePics, isRegeneratingPics, onOpenModal, isFetching, refetch }: Props) {
  const [activeMatchId, setActiveMatchId] = useState<string | null>(null)
  const activeMatch = activeMatchId ? (matches.find((m) => m.id === activeMatchId) ?? null) : null
  const [postModeGroups, setPostModeGroups] = useState<Record<string, boolean>>({})
  const [matchPhotos, setMatchPhotos] = useState<Record<string, HTMLImageElement>>({})
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const activeUploadMatchId = useRef<string | null>(null)

  const getPairName = (id: string | null) =>
    id ? (pairs.find((p) => p.id === id)?.name ?? id) : 'TBD'

  const handleDownloadGroup = (_g: GroupId, _groupMatches: TournamentMatch[], _pairIds: string[], _allMatches: TournamentMatch[]) => {}

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
