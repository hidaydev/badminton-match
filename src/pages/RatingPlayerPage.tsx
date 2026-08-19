// src/pages/RatingPlayerPage.tsx — detail rating pemain (plan §6.5)
import { Link, useParams } from 'react-router-dom'
import { useRatingPlayer } from '../queries/ratings'
import RatingTierBadge from '../components/ratings/RatingTierBadge'
import RatingSparkline from '../components/ratings/RatingSparkline'

export default function RatingPlayerPage() {
  const { playerId } = useParams<{ playerId: string }>()
  const { data, isLoading, isError } = useRatingPlayer(playerId)

  if (isLoading) return <p className="text-fg-dim text-sm">Loading rating…</p>
  if (isError) return <p className="text-error text-sm">Failed to load rating.</p>
  if (!data) return null

  const { name, rating, rd, tier, peak, games, wins, losses, history } = data
  const provisional = rd > 200
  // API DESC → balik untuk sparkline (kronologis); sparkline pakai new_rating
  const chrono = [...history].reverse().map((h) => ({ rating: h.new_rating }))

  return (
    <div className="flex flex-col gap-4">
      {/* Header */}
      <div className="flex items-start justify-between gap-2">
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center gap-2">
            <h2 className="text-lg font-bold text-fg">{name}</h2>
            <RatingTierBadge tier={tier} size="md" />
            {provisional && (
              <span className="text-[9px] font-bold text-amber-400/90 bg-amber-900/40 border border-amber-700/50 rounded px-1.5 py-0.5 uppercase tracking-wider">
                provisional
              </span>
            )}
          </div>
          <Link
            to={`/player-history/${encodeURIComponent(name)}`}
            className="text-xs text-accent hover:brightness-110 transition-colors"
          >
            Player history →
          </Link>
        </div>
        <span className="text-right">
          <span className="block text-2xl font-bold font-mono text-accent leading-none">{rating.toFixed(0)}</span>
          <span className="block text-[10px] font-mono text-fg-dim mt-1">RD {rd.toFixed(1)}</span>
        </span>
      </div>

      {/* Stat cards */}
      <div className="grid grid-cols-4 gap-2">
        {[
          { label: 'Peak', value: peak.toFixed(0) },
          { label: 'Games', value: String(games) },
          { label: 'W-L', value: `${wins}-${losses}` },
          { label: 'Tier', value: String(tier) },
        ].map((s) => (
          <div key={s.label} className="bg-surface border border-border-subtle rounded-lg p-2.5 text-center">
            <div className="text-base font-bold font-mono text-fg">{s.value}</div>
            <div className="text-[10px] font-mono text-fg-dim uppercase tracking-wider mt-0.5">{s.label}</div>
          </div>
        ))}
      </div>

      {/* Sparkline */}
      <div className="bg-surface border border-border-subtle rounded-lg p-3">
        <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider mb-2">Rating trend</p>
        <RatingSparkline points={chrono} />
      </div>

      {/* Recent matches */}
      <div className="flex flex-col gap-1.5">
        <p className="text-[10px] font-mono text-fg-dim uppercase tracking-wider px-1">Recent matches</p>
        {history.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-6">No matches yet.</p>}
        {history.map((h, i) => {
          const won = h.outcome === 'W'
          return (
            <div key={i} className="bg-surface border border-border-subtle rounded-lg px-3 py-2 flex items-center gap-3">
              <span className={`text-xs font-bold ${won ? 'text-emerald-400' : 'text-red-400'}`}>{won ? 'W' : 'L'}</span>
              <div className="flex-1 min-w-0">
                <p className="text-sm text-fg truncate">{h.title}</p>
                <p className="text-[10px] font-mono text-fg-dim">
                  {h.date} · {h.score_a}-{h.score_b} · {h.game_ref}
                </p>
              </div>
              <span className={`text-xs font-mono font-bold shrink-0 ${h.delta > 0 ? 'text-emerald-400' : 'text-red-400'}`}>
                {h.delta > 0 ? '+' : ''}{h.delta.toFixed(1)}
              </span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
