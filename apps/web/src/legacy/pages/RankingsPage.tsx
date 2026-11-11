// src/pages/RankingsPage.tsx: public leaderboard based on rolling 12-week points.
import { useId, useState, useMemo } from 'react'
import { useNavigate, useSearchParams } from '../router'
import { useRankings } from '../queries/ratings'
import AnnotatedPlayerName from '../components/AnnotatedPlayerName'
import RatingTierBadge from '../components/ratings/RatingTierBadge'
import { ALL_RATING_TIERS } from '../config/ratingTiers'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider } from '../context/AmbiguousNamesContext'
import { t } from '../../i18n'
import { Card } from '../../components/Card'
import { ErrorText } from '../../components/ErrorText'
import { StandingsTable } from '../../components/StandingsTable'

const LIMIT = 200

/**
 * The movement cell of one ranking row: one glyph and the sentence a screen
 * reader gets instead. Up is a climb, so a positive delta is the green arrow.
 */
function rankDelta(delta: number | null | undefined) {
  if (delta == null || delta === 0) {
    return (
      <>
        <span className="text-fg-dim" aria-hidden="true">·</span>
        <span className="sr-only">{t('rankings.deltaSame')}</span>
      </>
    )
  }
  if (delta > 0) {
    return (
      <>
        <span className="text-green-400" aria-hidden="true">▲</span>
        <span className="sr-only">{t('rankings.deltaUp', { n: delta })}</span>
      </>
    )
  }
  return (
    <>
      <span className="text-red-400" aria-hidden="true">▼</span>
      <span className="sr-only">{t('rankings.deltaDown', { n: -delta })}</span>
    </>
  )
}

export default function RankingsPage() {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()

  const selectedTier = searchParams.get('tier') || 'all'
  const [query, setQuery] = useState('')

  const handleTierChange = (tier: string) => {
    const next = new URLSearchParams(searchParams)
    if (tier === 'all') {
      next.delete('tier')
    } else {
      next.set('tier', tier)
    }
    setSearchParams(next, { replace: true })
  }

  // Fetch all active players in 12-week window (min_sessions=0).
  const { data, isLoading, isError, refetch } = useRankings(LIMIT, 0)
  const searchId = useId()
  const rawRows = useMemo(() => data?.rows ?? [], [data])

  // Count players per tier
  const tierCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const r of rawRows) {
      if (r.tier) {
        counts[r.tier] = (counts[r.tier] || 0) + 1
      }
    }
    return counts
  }, [rawRows])

  // Filter tier & calculate intra-tier rank
  const rowsWithRank = useMemo(() => {
    if (selectedTier === 'all') {
      return rawRows.map((r) => ({ ...r, displayRank: r.rank }))
    }
    const filteredByTier = rawRows.filter((r) => r.tier === selectedTier)
    // Tied points share rank (1, 2, 2, 4) within tier
    return filteredByTier.map((r, idx, arr) => {
      let displayRank = idx + 1
      if (idx > 0 && r.points === arr[idx - 1].points) {
        const firstIdx = arr.findIndex((x) => x.points === r.points)
        displayRank = firstIdx + 1
      }
      return { ...r, displayRank }
    })
  }, [selectedTier, rawRows])

  const ambiguousNames = useMemo(
    () => collectAmbiguousBaseNames(rawRows.map((r) => r.name)),
    [rawRows],
  )

  const filtered = query
    ? rowsWithRank.filter((r) => r.name.toLowerCase().includes(query.toLowerCase()))
    : rowsWithRank

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
      <div className="flex flex-col gap-3">
        {/* Header Title */}
        <div className="flex items-baseline justify-between gap-2">
          <h1 className="text-lg font-bold text-fg">{t('rankings.title')}</h1>
        </div>

        {/* Filter Tier Chips */}
        <div className="flex items-center gap-1.5 overflow-x-auto pb-1 no-scrollbar text-xs">
          <button
            type="button"
            onClick={() => handleTierChange('all')}
            className={`hit44 shrink-0 px-2.5 py-1 rounded-full font-medium transition-colors border ${
              selectedTier === 'all'
                ? 'bg-accent/20 text-accent border-accent/60 font-semibold'
                : 'bg-surface text-fg-dim border-border-subtle hover:text-fg hover:border-border'
            }`}
          >
            {t('common.all')} ({rawRows.length})
          </button>
          {ALL_RATING_TIERS.map((tier) => {
            const count = tierCounts[tier] || 0
            const isSelected = selectedTier === tier
            return (
              <button
                key={tier}
                type="button"
                onClick={() => handleTierChange(tier)}
                className={`hit44 shrink-0 px-2.5 py-1 rounded-full font-medium transition-colors border flex items-center gap-1 ${
                  isSelected
                    ? 'bg-accent/20 text-accent border-accent/60 font-semibold'
                    : count > 0
                      ? 'bg-surface text-fg-dim border-border-subtle hover:text-fg hover:border-border'
                      : 'bg-surface/50 text-fg-dim border-border-subtle/50'
                }`}
              >
                <span>{tier}</span>
                <span className="text-[10px] font-mono">({count})</span>
              </button>
            )
          })}
        </div>

        {/* Subtitle */}
        <p className="text-xs font-sans text-fg-dim">
          {selectedTier === 'all'
            ? t('rankings.allSubtitle')
            : t('rankings.tierSubtitle', { tier: selectedTier })}
        </p>

        {/* Search Input */}
        <label htmlFor={searchId} className="sr-only">
          {selectedTier === 'all' ? t('rankings.searchAll') : t('rankings.searchTier', { tier: selectedTier })}
        </label>
        <input
          id={searchId}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={selectedTier === 'all' ? t('rankings.searchAll') : t('rankings.searchTier', { tier: selectedTier })}
          className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim focus:border-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        />

        {isError && (
          <div className="flex items-center gap-3">
            <ErrorText>{t('rankings.loadFailed')}</ErrorText>
            <button
              type="button"
              onClick={() => void refetch()}
              className="text-xs font-medium text-accent hover:underline hit44"
            >
              {t('legacy.retry')}
            </button>
          </div>
        )}

        {!isError && isLoading && (
          <div className="bg-surface border border-border-subtle rounded-lg overflow-hidden animate-pulse">
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="flex items-center gap-3 px-4 py-3 border-b border-border-subtle last:border-0">
                <div className="w-5 h-3 bg-slate-700 rounded" />
                <div className="flex-1 h-4 bg-slate-700 rounded" />
                <div className="w-14 h-4 bg-slate-700 rounded" />
              </div>
            ))}
          </div>
        )}

        {!isError && !isLoading && rawRows.length === 0 && (
          <p className="text-fg-dim text-xs font-sans text-center py-8">
            {t('rankings.noPointsYet')}
          </p>
        )}

        {!isError && !isLoading && filtered.length > 0 && (
          <Card variant="flush" as="ol" radius="lg" className="divide-y divide-border-subtle">
            <StandingsTable
              layout="rank"
              rows={filtered.map((r) => ({
                key: r.player_id,
                rank: r.displayRank,
                rankDetail: selectedTier === 'all' ? undefined : r.rank,
                highlighted: r.displayRank === 1,
                name: <AnnotatedPlayerName name={r.name} />,
                nameExtra: r.tier ? <RatingTierBadge tier={r.tier} size="sm" /> : undefined,
                delta: selectedTier === 'all' ? rankDelta(r.rank_delta) : undefined,
                pointsFor: Math.round(r.points),
                onSelect: () => navigate(`/rankings/${r.player_id}`),
              }))}
            />
          </Card>
        )}

        {!isError && !isLoading && filtered.length === 0 && (
          <p className="text-fg-dim text-xs font-sans text-center py-8">
            {query
              ? t('rankings.noMatchesQuery', { query })
              : selectedTier !== 'all'
                ? t('rankings.noPlayersInTier', { tier: selectedTier })
                : t('rankings.noPlayers')}
          </p>
        )}
      </div>
    </AmbiguousNamesProvider>
  )
}
