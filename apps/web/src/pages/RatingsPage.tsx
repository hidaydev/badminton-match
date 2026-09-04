// src/pages/RatingsPage.tsx — leaderboard rating (plan RATINGS_FRONTEND_PLAN.md §6.4)
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useRatingLeaderboard, useRatingSeasons, useSeasonStandings } from '../queries/ratings'
import RatingTierBadge from '../components/ratings/RatingTierBadge'

const PAGE = 100

export default function RatingsPage() {
  const navigate = useNavigate()
  const [active, setActive] = useState(true)
  const [offset, setOffset] = useState(0)
  const [query, setQuery] = useState('')
  // Season picker (Rev 3.7): null = musim berjalan (live); id = arsip beku
  const [seasonId, setSeasonId] = useState<string | null>(null)
  const { data: seasons } = useRatingSeasons()

  const { data, isLoading, isError, isFetching } = useRatingLeaderboard(active, PAGE, offset)
  const { data: frozen, isLoading: frozenLoading } = useSeasonStandings(seasonId)

  const rows = data?.rows ?? []
  const total = data?.total ?? 0
  const loading = isLoading
  const error = isError

  // Client-side filter (kaya AdminPlayersPage) — filter rows yang udah ke-load (PAGE 100)
  const filtered = query ? rows.filter((r) => r.name.toLowerCase().includes(query.toLowerCase())) : rows

  // Show empty state when offset exceeds total (data changed while paginated)
  const showEmpty = !loading && !error && rows.length === 0 && total > 0

  return (
    <div className="flex flex-col gap-3">
      {/* Header */}
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-lg font-bold text-fg">Ratings</h2>
        <div className="flex items-center gap-2">
        <select
          value={seasonId ?? ''}
          onChange={(e) => { setSeasonId(e.target.value || null); setOffset(0) }}
          className="bg-elevated border border-border-subtle rounded-lg px-2 py-1.5 text-xs font-sans text-fg focus:outline-none focus:border-accent"
          aria-label="Pilih musim"
        >
          <option value="">Current season</option>
          {(seasons ?? []).filter((s) => !s.open).map((s) => (
            <option key={s.id} value={s.id}>{s.name} (closed)</option>
          ))}
        </select>
        <div className="flex rounded-lg overflow-hidden border border-border-subtle">
          {([true, false] as const).map((a) => (
            <button
              key={String(a)}
              onClick={() => { setActive(a); setOffset(0) }}
              className={`px-3 py-1.5 text-xs font-semibold transition-colors ${
                active === a ? 'bg-accent text-slate-950' : 'text-fg-dim hover:text-fg'
              }`}
            >
              {a ? 'Active' : 'All'}
            </button>
          ))}
        </div>
        </div>
      </div>

      {/* Search — client-side, kaya AdminPlayersPage */}
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search player…"
        className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
      />

      <p className="text-xs font-sans text-fg-dim">
        {loading ? 'Loading…' : query ? <><span className="text-accent">{filtered.length}</span> / {total} players · filtered by &ldquo;{query}&rdquo;</> : <><span className="text-accent">{total}</span> player{total !== 1 ? 's' : ''} · updates automatically when sessions lock</>}
      </p>

      {error && <p className="text-error text-sm">Failed to load ratings.</p>}
      {!error && loading && (
        <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden animate-pulse">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="flex items-center gap-3 px-4 py-3 border-b border-border-subtle last:border-0">
              <div className="w-5 h-3 bg-slate-700 rounded" />
              <div className="w-6 h-5 bg-slate-700 rounded" />
              <div className="flex-1 h-4 bg-slate-700 rounded" />
              <div className="w-12 h-4 bg-slate-700 rounded" />
            </div>
          ))}
        </div>
      )}

      {!error && !loading && rows.length === 0 && (
        <p className="text-fg-dim text-xs font-sans text-center py-8">
          No ratings yet — ratings appear automatically once sessions are locked.
        </p>
      )}

      {/* Arsip musim tertutup — standings beku */}
      {seasonId && !frozenLoading && (frozen ?? []).length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden divide-y divide-border-subtle">
          {(frozen ?? []).map((r, i) => (
            <div key={i} className="flex items-center gap-3 px-4 py-2.5">
              <span className={`w-6 text-sm font-sans shrink-0 ${i === 0 ? 'text-accent' : i < 3 ? 'text-slate-200' : 'text-fg-dim'}`}>{i + 1}</span>
              <RatingTierBadge tier={r.tier_display} />
              <span className="flex-1 min-w-0 truncate text-sm font-medium text-fg">{r.name}</span>
              <span className="shrink-0 text-right font-sans">
                <span className="block text-sm font-bold text-fg">{r.rating.toFixed(0)}</span>
                <span className="block text-[10px] text-fg-dim">{r.games} game{r.games !== 1 ? 's' : ''} · {r.wins}-{r.losses}</span>
              </span>
            </div>
          ))}
        </div>
      )}

      {!error && !loading && filtered.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden divide-y divide-border-subtle">
          {filtered.map((r) => {
            const originalIdx = rows.findIndex((x) => x.player_id === r.player_id)
            const rank = offset + originalIdx + 1
            const isFirst = rank === 1
            const isSecond = rank === 2
            const isThird = rank === 3
            const medal = isFirst ? 'text-accent' : isSecond ? 'text-slate-200' : isThird ? 'text-amber-700' : 'text-fg-dim'
            const rowBg = isFirst || isSecond || isThird ? 'bg-accent/[0.04]' : ''
            const trendColor = r.trend > 0 ? 'text-emerald-400' : r.trend < 0 ? 'text-red-400' : 'text-fg-dim'
            const trendLabel = r.trend > 0 ? `+${r.trend.toFixed(1)}` : r.trend < 0 ? r.trend.toFixed(1) : '–'

            return (
              <button
                key={r.player_id}
                onClick={() => navigate(`/ratings/${r.player_id}`)}
                className={`w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-elevated transition-colors ${rowBg}`}
              >
                <span className={`w-6 text-sm font-sans shrink-0 ${medal}`}>{rank}</span>
                <RatingTierBadge tier={r.tier_display} />
                <span className="flex-1 min-w-0">
                  <span className="block text-sm font-medium text-fg truncate">{r.name}</span>
                  <span className="block text-[10px] font-sans text-fg-dim">
                    {r.games} game{r.games !== 1 ? 's' : ''}
                  </span>
                </span>
                <span className="shrink-0 text-right">
                  <span className="block text-sm font-bold font-sans text-fg">{r.rating.toFixed(0)}</span>
                  <span className="block text-[10px] font-sans flex items-center gap-1 justify-end">
                    <span className={trendColor}>{trendLabel}</span>
                    {r.provisional && (
                      <span className="text-amber-400/90 bg-amber-900/40 border border-amber-700/50 rounded px-1 uppercase tracking-wider text-[8px]">
                        prov
                      </span>
                    )}
                  </span>
                </span>
              </button>
            )
          })}
        </div>
      )}

      {!error && !loading && filtered.length === 0 && query && rows.length > 0 && (
        <p className="text-fg-dim text-xs font-sans text-center py-8">
          No players match &ldquo;{query}&rdquo; — try different spelling{offset + rows.length < total ? ' or load more' : ''}.
        </p>
      )}

      {showEmpty && (
        <p className="text-fg-dim text-xs text-center py-8">
          No results. Try changing filters or go back to first page.
        </p>
      )}

      {!error && !loading && offset + rows.length < total && (
        <button
          onClick={() => setOffset((o) => o + PAGE)}
          disabled={isFetching}
          className="w-full py-2.5 rounded-lg border border-border-subtle text-sm font-semibold text-fg-dim hover:text-fg hover:border-border disabled:opacity-40 transition-colors"
        >
          {isFetching ? 'Loading…' : `Load more (${total - offset - rows.length} left)`}
        </button>
      )}
    </div>
  )
}
