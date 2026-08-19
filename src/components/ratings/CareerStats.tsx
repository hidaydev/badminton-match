// src/components/ratings/CareerStats.tsx — career stats pemain (bekas
// PlayerDetailPage, diserap ke /ratings/:playerId — UI_UX_POLISH_PLAN §4).
import type { PlayerStats } from '../../queries/types'

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-surface border border-border-subtle rounded-lg p-3 text-center">
      <div className="text-base font-bold font-mono text-fg">{value}</div>
      <div className="text-[10px] font-mono text-fg-dim uppercase tracking-wider mt-0.5">{label}</div>
    </div>
  )
}

function PairRow({ name, wins, losses, count }: { name: string; wins: number; losses: number; count: number }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-sm text-fg truncate min-w-0">{name}</span>
      <div className="flex items-center gap-1.5 font-mono text-[10px] shrink-0">
        <span className="text-emerald-400 font-semibold">{wins}W</span>
        {losses > 0 && <span className="text-red-400 font-semibold">{losses}L</span>}
        <span className="text-fg-dim">{count}×</span>
      </div>
    </div>
  )
}

export default function CareerStats({ stats }: { stats: PlayerStats }) {
  const winRate = stats.gamesPlayed > 0 ? Math.round((stats.wins / stats.gamesPlayed) * 100) : 0
  const tWinRate = stats.tournamentStats.gamesPlayed > 0
    ? Math.round((stats.tournamentStats.wins / stats.tournamentStats.gamesPlayed) * 100)
    : 0

  return (
    <div className="flex flex-col gap-4">
      {/* Overview */}
      <div className="grid grid-cols-4 gap-2">
        <StatCard label="Games" value={String(stats.gamesPlayed)} />
        <StatCard label="Win Rate" value={`${winRate}%`} />
        <StatCard label="Wins" value={String(stats.wins)} />
        <StatCard label="Losses" value={String(stats.losses)} />
      </div>

      {/* Sessions */}
      {stats.sessions.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
          <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">Sessions ({stats.sessions.length})</p>
          {stats.sessions.map((s) => (
            <div key={s.id} className="flex justify-between items-center text-sm gap-2">
              <span className={s.absent ? 'text-fg-dim line-through truncate min-w-0' : 'text-fg truncate min-w-0'}>
                {s.title || 'Untitled'}
              </span>
              <div className="flex items-center gap-2 shrink-0">
                {s.absent && <span className="text-[10px] font-mono text-fg-dim">absent</span>}
                <span className="text-[10px] font-mono text-fg-dim">{s.date.split('-').reverse().join('-')}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Top partners & opponents */}
      {stats.topPartners.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
          <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">Top Partners</p>
          {stats.topPartners.map((p) => (
            <PairRow key={p.name} name={p.name} wins={p.wins} losses={p.losses} count={p.count} />
          ))}
        </div>
      )}

      {stats.topOpponents.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
          <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">Top Opponents</p>
          {stats.topOpponents.map((p) => (
            <PairRow key={p.name} name={p.name} wins={p.wins} losses={p.losses} count={p.count} />
          ))}
        </div>
      )}

      {/* Tournament career */}
      {stats.tournamentStats.gamesPlayed > 0 && (
        <>
          <div className="grid grid-cols-4 gap-2">
            <StatCard label="Tourn Games" value={String(stats.tournamentStats.gamesPlayed)} />
            <StatCard label="Tourn W/R" value={`${tWinRate}%`} />
            <StatCard label="Tourn W" value={String(stats.tournamentStats.wins)} />
            <StatCard label="Tourn L" value={String(stats.tournamentStats.losses)} />
          </div>

          {stats.tournamentStats.tournaments.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
              <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">
                Tournaments ({stats.tournamentStats.tournaments.length})
              </p>
              {stats.tournamentStats.tournaments.map((t) => (
                <div key={t.name} className="flex justify-between items-center text-sm gap-2">
                  <span className="text-fg truncate min-w-0">{t.name}</span>
                  <div className="flex items-center gap-2 shrink-0 font-mono text-[10px]">
                    <span className="text-emerald-400 font-semibold">{t.wins}W</span>
                    <span className="text-red-400 font-semibold">{t.losses}L</span>
                    <span className="text-fg-dim">{t.games} games</span>
                    <span className="text-fg-dim">{t.date.split('-').reverse().join('-')}</span>
                  </div>
                </div>
              ))}
            </div>
          )}

          {stats.tournamentStats.topPartners.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
              <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">Tournament Partners</p>
              {stats.tournamentStats.topPartners.map((p) => (
                <PairRow key={p.name} name={p.name} wins={p.wins} losses={0} count={p.count} />
              ))}
            </div>
          )}

          {stats.tournamentStats.topOpponents.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
              <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">Tournament Opponents</p>
              {stats.tournamentStats.topOpponents.map((p) => (
                <PairRow key={p.name} name={p.name} wins={p.wins} losses={0} count={p.count} />
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}
