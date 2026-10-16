// src/pages/RankingsPage.tsx: papan poin publik (ala BWF).
//
// Papan ini memakai POIN (window bergulir 12 minggu, 10 entri terbaik),
// bukan rating Glicko. Glicko tetap ada di halaman detail pemain; papan
// Glicko dipindah ke admin supaya pemain tidak melihat dua angka berbeda.
//
// Menampilkan seluruh pemain aktif dengan filter per-level (tier).
import { useState, useMemo } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useRankings } from '../queries/ratings'
import AnnotatedPlayerName from '../components/AnnotatedPlayerName'
import RatingTierBadge from '../components/ratings/RatingTierBadge'
import { ALL_RATING_TIERS } from '../config/ratingTiers'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider } from '../context/AmbiguousNamesContext'

const LIMIT = 200

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

  // Mengambil seluruh pemain aktif di window 12 minggu (min_sessions=0).
  const { data, isLoading, isError } = useRankings(LIMIT, 0)
  const rawRows = useMemo(() => data?.rows ?? [], [data])

  // Hitung jumlah pemain per tier
  const tierCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const r of rawRows) {
      if (r.tier) {
        counts[r.tier] = (counts[r.tier] || 0) + 1
      }
    }
    return counts
  }, [rawRows])

  // Filter tier & hitung peringkat intra-level
  const rowsWithRank = useMemo(() => {
    if (selectedTier === 'all') {
      return rawRows.map((r) => ({ ...r, displayRank: r.rank }))
    }
    const filteredByTier = rawRows.filter((r) => r.tier === selectedTier)
    // Peringkat seri dibagi (1,2,2,4) di dalam level
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
          <h2 className="text-lg font-bold text-fg">Ranking</h2>
        </div>

        {/* Filter Tier Chips */}
        <div className="flex items-center gap-1.5 overflow-x-auto pb-1 no-scrollbar text-xs">
          <button
            type="button"
            onClick={() => handleTierChange('all')}
            className={`shrink-0 px-2.5 py-1 rounded-full font-medium transition-colors border ${
              selectedTier === 'all'
                ? 'bg-accent/20 text-accent border-accent/60 font-semibold'
                : 'bg-surface text-fg-dim border-border-subtle hover:text-fg hover:border-border'
            }`}
          >
            Semua ({rawRows.length})
          </button>
          {ALL_RATING_TIERS.map((tier) => {
            const count = tierCounts[tier] || 0
            const isSelected = selectedTier === tier
            return (
              <button
                key={tier}
                type="button"
                onClick={() => handleTierChange(tier)}
                className={`shrink-0 px-2.5 py-1 rounded-full font-medium transition-colors border flex items-center gap-1 ${
                  isSelected
                    ? 'bg-accent/20 text-accent border-accent/60 font-semibold'
                    : count > 0
                      ? 'bg-surface text-fg-dim border-border-subtle hover:text-fg hover:border-border'
                      : 'bg-surface/50 text-fg-dim/40 border-border-subtle/50'
                }`}
              >
                <span>{tier}</span>
                <span className="text-[10px] font-mono opacity-70">({count})</span>
              </button>
            )
          })}
        </div>

        {/* Penjelasan singkat */}
        <p className="text-xs font-sans text-fg-dim">
          {selectedTier === 'all'
            ? 'Papan ranking seluruh pemain aktif (12 minggu terakhir). Pilih level di atas untuk melihat peringkat spesifik antarpemain selevel.'
            : `Peringkat antarpemain di Level ${selectedTier}. Peringkat utama menunjukkan posisi di level ini.`}
        </p>

        {/* Search Input */}
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={selectedTier === 'all' ? 'Cari pemain…' : `Cari pemain di level ${selectedTier}…`}
          className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500/50"
        />

        {isError && <p className="text-error text-sm">Gagal memuat ranking.</p>}

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
            Belum ada poin. Ranking muncul setelah sesi dikunci dan dinilai.
          </p>
        )}

        {!isError && !isLoading && filtered.length > 0 && (
          <ol className="bg-surface border border-border-subtle rounded-lg overflow-hidden divide-y divide-border-subtle">
            {filtered.map((r) => {
              const isFirst = r.displayRank === 1
              const rankColor = isFirst ? 'text-accent font-bold' : 'text-fg-dim'
              const rowBg = isFirst ? 'bg-accent/[0.04]' : ''
              const showDelta = selectedTier === 'all'
              const isFilteredTier = selectedTier !== 'all'

              return (
                <li key={r.player_id}>
                  <button
                    onClick={() => navigate(`/rankings/${r.player_id}`)}
                    className={`w-full flex items-center gap-2.5 px-3.5 py-2.5 text-left hover:bg-elevated transition-colors ${rowBg}`}
                  >
                    {/* Rank Number (dan Global Rank bila sedang filter tier) */}
                    <div className="w-9 shrink-0 flex flex-col items-start justify-center">
                      <span className={`font-mono text-sm leading-none ${rankColor}`}>
                        #{r.displayRank}
                      </span>
                      {isFilteredTier && (
                        <span className="text-[9px] font-mono text-fg-dim/60 leading-tight mt-0.5">
                          #{r.rank}
                        </span>
                      )}
                    </div>

                    {/* Movement Indicator (▲ / ▼ / ·) saat view Semua */}
                    {showDelta && (
                      <span className="w-3 shrink-0 font-mono text-[10px] leading-none text-center">
                        {r.rank_delta == null || r.rank_delta === 0 ? (
                          <>
                            <span className="text-fg-dim/40" aria-hidden="true">·</span>
                            <span className="sr-only">tetap</span>
                          </>
                        ) : r.rank_delta > 0 ? (
                          <>
                            <span className="text-green-400" aria-hidden="true">▲</span>
                            <span className="sr-only">naik {r.rank_delta} peringkat</span>
                          </>
                        ) : (
                          <>
                            <span className="text-red-400" aria-hidden="true">▼</span>
                            <span className="sr-only">turun {-r.rank_delta} peringkat</span>
                          </>
                        )}
                      </span>
                    )}

                    {/* Player Name & Tier Badge */}
                    <div className="flex-1 min-w-0 flex items-center gap-2">
                      <span className="text-sm font-medium text-fg truncate">
                        <AnnotatedPlayerName name={r.name} />
                      </span>
                      {r.tier && <RatingTierBadge tier={r.tier} size="sm" />}
                    </div>

                    {/* Points */}
                    <div className="shrink-0 flex items-center">
                      <span className="font-mono text-sm font-bold text-fg leading-none">
                        {Math.round(r.points).toLocaleString('id-ID')}
                      </span>
                    </div>
                  </button>
                </li>
              )
            })}
          </ol>
        )}

        {!isError && !isLoading && filtered.length === 0 && (
          <p className="text-fg-dim text-xs font-sans text-center py-8">
            {query
              ? `Tidak ada pemain yang cocok dengan \u201C${query}\u201D.`
              : selectedTier !== 'all'
                ? `Belum ada pemain aktif di Level ${selectedTier}.`
                : 'Tidak ada pemain untuk ditampilkan.'}
          </p>
        )}
      </div>
    </AmbiguousNamesProvider>
  )
}
