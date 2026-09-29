// src/pages/RankingsPage.tsx: papan poin publik (ala BWF).
//
// Papan ini memakai POIN (window bergulir 12 minggu, 10 entri terbaik),
// bukan rating Glicko. Glicko tetap ada di halaman detail pemain; papan
// Glicko dipindah ke admin supaya pemain tidak melihat dua angka berbeda.
import { useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useRankings } from '../queries/ratings'
import AnnotatedPlayerName from '../components/AnnotatedPlayerName'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider } from '../context/AmbiguousNamesContext'

const LIMIT = 200

export default function RankingsPage() {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const { data, isLoading, isError } = useRankings(LIMIT)

  const rows = useMemo(() => data?.rows ?? [], [data])
  const ambiguousNames = useMemo(
    () => collectAmbiguousBaseNames(rows.map((r) => r.name)),
    [rows],
  )

  const filtered = query
    ? rows.filter((r) => r.name.toLowerCase().includes(query.toLowerCase()))
    : rows

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
      <div className="flex flex-col gap-3">
        <div className="flex items-baseline justify-between gap-2">
          <h2 className="text-lg font-bold text-fg">Ranking</h2>
          {data && rows.length > 0 && (
            <span className="text-[10px] font-mono text-fg-dim uppercase">
              {data.window_weeks} minggu · {data.best_n} terbaik
            </span>
          )}
        </div>

        {/* Penjelasan singkat: angka ini bukan rating, dan apa yang dihitung. */}
        <p className="text-xs font-sans text-fg-dim">
          {data && rows.length > 0
            ? <>Total poin dari sesi terbaik dalam {data.window_weeks} minggu terakhir. Poin dihitung dari skor dan kekuatan lawan.</>
            : 'Poin dihitung dari skor tiap sesi dan kekuatan lawan.'}
        </p>

        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Cari pemain…"
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

        {!isError && !isLoading && rows.length === 0 && (
          <p className="text-fg-dim text-xs font-sans text-center py-8">
            Belum ada poin. Ranking muncul setelah sesi dikunci dan dinilai.
          </p>
        )}

        {!isError && !isLoading && filtered.length > 0 && (
          <ol className="bg-surface border border-border-subtle rounded-lg overflow-hidden divide-y divide-border-subtle">
            {filtered.map((r) => {
              // Accent hanya untuk juara: hierarki, bukan dekorasi.
              const rankColor = r.rank === 1 ? 'text-accent' : 'text-fg-dim'
              const rowBg = r.rank === 1 ? 'bg-accent/[0.04]' : ''
              return (
                <li key={r.player_id}>
                  <button
                    onClick={() => navigate(`/rankings/${r.player_id}`)}
                    className={`w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-elevated transition-colors ${rowBg}`}
                  >
                    <span className={`w-6 shrink-0 font-mono text-sm ${rankColor}`}>{r.rank}</span>
                    <span className="w-3 shrink-0 font-mono text-[10px] leading-none">
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
                    <span className="flex-1 min-w-0 text-sm font-medium text-fg truncate">
                      <AnnotatedPlayerName name={r.name} />
                    </span>
                    <span className="shrink-0 font-mono text-sm font-bold text-fg">
                      {Math.round(r.points).toLocaleString('id-ID')}
                    </span>
                  </button>
                </li>
              )
            })}
          </ol>
        )}

        {!isError && !isLoading && filtered.length === 0 && query && rows.length > 0 && (
          <p className="text-fg-dim text-xs font-sans text-center py-8">
            Tidak ada pemain yang cocok dengan &ldquo;{query}&rdquo;.
          </p>
        )}
      </div>
    </AmbiguousNamesProvider>
  )
}
