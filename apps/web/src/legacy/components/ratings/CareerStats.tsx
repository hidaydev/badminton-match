// src/components/ratings/CareerStats.tsx — player career stats.
import { useState } from 'react'
import AnnotatedPlayerName from '../AnnotatedPlayerName'
import type { PlayerStats } from '../../queries/types'
import { t } from '../../i18n'

const SESSIONS_PER_PAGE = 5

function PairRow({ name, wins, losses, count }: { name: string; wins: number; losses: number; count: number }) {
  return (
    <div className="flex items-center justify-between gap-1.5 py-1 border-b border-border-subtle/40 last:border-0">
      <span className="text-xs text-fg truncate min-w-0 font-medium">
        <AnnotatedPlayerName name={name} />
      </span>
      <div className="flex items-center gap-1 font-mono text-[10px] shrink-0">
        <span className="text-emerald-400 font-semibold">{wins}W</span>
        {losses > 0 && <span className="text-red-400 font-semibold">{losses}L</span>}
        <span className="text-fg-dim font-sans">{count}×</span>
      </div>
    </div>
  )
}

export default function CareerStats({ stats, countedPoints }: {
  stats: PlayerStats
  // source_id (session share_code) -> points contributed to ranking.
  countedPoints?: Map<string, number>
}) {
  const tWinRate = stats.tournamentStats.gamesPlayed > 0
    ? Math.round((stats.tournamentStats.wins / stats.tournamentStats.gamesPlayed) * 100)
    : 0
  const [sessionsPage, setSessionsPage] = useState(0)
  const sessionsTotal = Math.ceil(stats.sessions.length / SESSIONS_PER_PAGE)

  return (
    <div className="flex flex-col gap-3">
      {/* Sessions History */}
      {stats.sessions.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-xl p-3.5 sm:p-4 flex flex-col gap-2">
          <div className="flex items-center justify-between pb-0.5">
            <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">
              {t('career.sessions')} ({stats.sessions.length})
              <span className="normal-case tracking-normal opacity-80"> {t('career.ratedNote')}</span>
            </p>
          </div>
          <div className="flex flex-col">
            {stats.sessions.slice(sessionsPage * SESSIONS_PER_PAGE, (sessionsPage + 1) * SESSIONS_PER_PAGE).map((s) => {
              const pts = s.share_code ? countedPoints?.get(s.share_code) : undefined
              const counted = pts !== undefined
              return (
                <div key={s.id} className="flex justify-between items-center text-sm gap-2 py-1.5 border-b border-border-subtle/50 last:border-0">
                  <span className={s.absent ? 'text-fg-dim/60 line-through truncate min-w-0 font-medium' : 'text-fg truncate min-w-0 font-medium'}>
                    {s.title || 'Untitled'}
                  </span>
                  <div className="flex items-center gap-2 shrink-0">
                    {counted && (
                      <span
                        className="text-[10px] font-mono text-accent bg-accent/10 border border-accent/30 rounded px-1.5 py-0.5 font-bold"
                        title={`Rank points contributed: +${Math.round(pts).toLocaleString('en-US')}`}
                      >
                        +{Math.round(pts).toLocaleString('en-US')} pts
                      </span>
                    )}
                    {s.absent && (
                      <span className="text-[10px] font-sans text-fg-dim/70 bg-elevated px-1.5 py-0.5 rounded border border-border-subtle">
                        {t('career.absent')}
                      </span>
                    )}
                    <span className="text-[10px] font-mono text-fg-dim">{s.date.split('-').reverse().join('-')}</span>
                  </div>
                </div>
              )
            })}
          </div>
          {sessionsTotal > 1 && (
            <div className="flex items-center justify-between pt-1">
              <button
                onClick={() => setSessionsPage((p) => Math.max(0, p - 1))}
                disabled={sessionsPage === 0}
                className="px-3.5 py-1.5 rounded-lg border border-border-subtle bg-surface text-xs font-medium text-fg-dim hover:text-fg hover:border-border disabled:opacity-30 disabled:pointer-events-none active:scale-95 transition-all"
              >
                {t('common.prev')}
              </button>
              <span className="text-xs font-mono text-fg-dim">
                {sessionsPage + 1} / {sessionsTotal}
              </span>
              <button
                onClick={() => setSessionsPage((p) => Math.min(sessionsTotal - 1, p + 1))}
                disabled={sessionsPage >= sessionsTotal - 1}
                className="px-3.5 py-1.5 rounded-lg border border-border-subtle bg-surface text-xs font-medium text-fg-dim hover:text-fg hover:border-border disabled:opacity-30 disabled:pointer-events-none active:scale-95 transition-all"
              >
                {t('common.next')}
              </button>
            </div>
          )}
        </div>
      )}

      {/* Top partners & opponents — 2 columns */}
      {(stats.topPartners.length > 0 || stats.topOpponents.length > 0) && (
        <div
          className={
            stats.topPartners.length > 0 && stats.topOpponents.length > 0
              ? 'grid grid-cols-2 gap-2'
              : 'flex flex-col gap-2'
          }
        >
          {stats.topPartners.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-xl p-3 flex flex-col gap-1.5">
              <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">
                {t('career.topPartners')}
              </p>
              {stats.topPartners.map((p) => (
                <PairRow key={p.name} name={p.name} wins={p.wins} losses={p.losses} count={p.count} />
              ))}
            </div>
          )}

          {stats.topOpponents.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-xl p-3 flex flex-col gap-1.5">
              <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">
                {t('career.topOpponents')}
              </p>
              {stats.topOpponents.map((p) => (
                <PairRow key={p.name} name={p.name} wins={p.wins} losses={p.losses} count={p.count} />
              ))}
            </div>
          )}
        </div>
      )}

      {/* Tournament career */}
      {stats.tournamentStats.gamesPlayed > 0 && (
        <div className="flex flex-col gap-3">
          <div className="grid grid-cols-3 gap-2 sm:gap-3">
            {/* Tourn Games */}
            <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
              <span className="text-xl sm:text-2xl font-bold font-mono text-fg leading-none">
                {stats.tournamentStats.gamesPlayed}
              </span>
              <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1.5 font-medium">
                {t('career.tournGames')}
              </span>
            </div>

            {/* Tourn W - L */}
            <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
              <div className="text-xl sm:text-2xl font-bold font-mono leading-none flex items-center justify-center gap-1">
                <span className="text-emerald-400">{stats.tournamentStats.wins}W</span>
                <span className="text-fg-dim/40 text-sm font-light">/</span>
                <span className="text-red-400">{stats.tournamentStats.losses}L</span>
              </div>
              <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1.5 font-medium">
                {t('career.tournWl')}
              </span>
            </div>

            {/* Tourn Win Rate */}
            <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
              <span className="text-xl sm:text-2xl font-bold font-mono text-fg leading-none">
                {tWinRate}%
              </span>
              {stats.tournamentStats.gamesPlayed > 0 && (
                <div className="w-14 mx-auto h-1 bg-ground rounded-full overflow-hidden mt-1.5">
                  <div
                    className="h-full bg-emerald-500 rounded-full transition-all"
                    style={{ width: `${Math.min(100, Math.max(0, tWinRate))}%` }}
                  />
                </div>
              )}
              <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1 font-medium">
                {t('career.tournWinRate')}
              </span>
            </div>
          </div>

          {stats.tournamentStats.tournaments.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-xl p-3.5 sm:p-4 flex flex-col gap-2">
              <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold pb-0.5">
                {t('career.tournaments')} ({stats.tournamentStats.tournaments.length})
              </p>
              <div className="flex flex-col">
                {stats.tournamentStats.tournaments.map((tItem) => {
                  const tPts = tItem.share_code ? countedPoints?.get(tItem.share_code) : undefined
                  return (
                    <div key={tItem.share_code || tItem.name} className="flex justify-between items-center text-sm gap-2 py-1.5 border-b border-border-subtle/50 last:border-0">
                      <span className="text-fg font-medium truncate min-w-0">{tItem.name}</span>
                      <div className="flex items-center gap-2 shrink-0 font-mono text-[10px]">
                        {tPts !== undefined && (
                          <span
                            className="text-accent bg-accent/10 border border-accent/30 rounded px-1.5 py-0.5 font-bold"
                            title={`Rank points contributed: +${Math.round(tPts).toLocaleString('en-US')}`}
                          >
                            +{Math.round(tPts).toLocaleString('en-US')} pts
                          </span>
                        )}
                        <span className="text-emerald-400 font-bold bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20">
                          {tItem.wins}W
                        </span>
                        <span className="text-red-400 font-bold bg-red-500/10 px-1.5 py-0.5 rounded border border-red-500/20">
                          {tItem.losses}L
                        </span>
                        <span className="text-fg-dim font-sans">{tItem.games} {t('career.games')}</span>
                        <span className="text-fg-dim">{tItem.date.split('-').reverse().join('-')}</span>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {(stats.tournamentStats.topPartners.length > 0 || stats.tournamentStats.topOpponents.length > 0) && (
            <div
              className={
                stats.tournamentStats.topPartners.length > 0 && stats.tournamentStats.topOpponents.length > 0
                  ? 'grid grid-cols-2 gap-2'
                  : 'flex flex-col gap-2'
              }
            >
              {stats.tournamentStats.topPartners.length > 0 && (
                <div className="bg-surface border border-border-subtle rounded-xl p-3 flex flex-col gap-1.5">
                  <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">
                    {t('career.tournamentPartners')}
                  </p>
                  {stats.tournamentStats.topPartners.map((p) => (
                    <PairRow key={p.name} name={p.name} wins={p.wins} losses={0} count={p.count} />
                  ))}
                </div>
              )}

              {stats.tournamentStats.topOpponents.length > 0 && (
                <div className="bg-surface border border-border-subtle rounded-xl p-3 flex flex-col gap-1.5">
                  <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">
                    {t('career.tournamentOpponents')}
                  </p>
                  {stats.tournamentStats.topOpponents.map((p) => (
                    <PairRow key={p.name} name={p.name} wins={p.wins} losses={0} count={p.count} />
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
