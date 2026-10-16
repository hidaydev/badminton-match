// src/pages/RatingPlayerPage.tsx: detail rating + career pemain.
// Tampilan mobile-first modern: Athlete Hero Card, 3-kolom stat bar,
// scorecard pertandingan terakhir, dan rekam jejak sesi & turnamen.
import { useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useRatingPlayer, useRatingPlayerAchievements, usePlayerRankPoints } from '../queries/ratings'
import { useGetPlayerStats } from '../queries'
import RatingTierBadge from '../components/ratings/RatingTierBadge'
import CareerStats from '../components/ratings/CareerStats'
import AchievementBadge from '../components/ratings/AchievementBadge'
import AchievementDetailModal from '../components/ratings/AchievementDetailModal'
import MedalHoneycomb from '../components/ratings/MedalHoneycomb'
import { isEventKey, medalIcon, seedFromKey } from '../utils/achievementBadge'
import type { AchievementRow } from '../queries/endpoints'

import AnnotatedPlayerName from '../components/AnnotatedPlayerName'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider, combineAmbiguous, useAmbiguousNames } from '../context/AmbiguousNamesContext'

const MATCHES_PER_PAGE = 5

function getInitials(name: string): string {
  const parts = name.trim().split(/\s+/)
  if (parts.length === 0 || !parts[0]) return '?'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}

export default function RatingPlayerPage() {
  const { playerId } = useParams<{ playerId: string }>()
  const navigate = useNavigate()
  const { data, isLoading, isError } = useRatingPlayer(playerId)
  const { data: stats } = useGetPlayerStats(data?.name ?? '')
  const { data: achievements, isLoading: achLoading, isError: achError } = useRatingPlayerAchievements(playerId)
  const { data: rankPoints, isLoading: rankLoading } = usePlayerRankPoints(playerId)
  const [matchesPage, setMatchesPage] = useState(0)
  const [selectedAchievement, setSelectedAchievement] = useState<AchievementRow | null>(null)
  const globalAmbiguous = useAmbiguousNames()

  if (isLoading) {
    return (
      <div className="flex flex-col gap-4 py-8 animate-pulse">
        <div className="h-32 bg-surface border border-border-subtle rounded-2xl" />
        <div className="grid grid-cols-3 gap-2">
          <div className="h-18 bg-surface border border-border-subtle rounded-xl" />
          <div className="h-18 bg-surface border border-border-subtle rounded-xl" />
          <div className="h-18 bg-surface border border-border-subtle rounded-xl" />
        </div>
        <div className="h-48 bg-surface border border-border-subtle rounded-xl" />
      </div>
    )
  }

  if (isError) {
    return (
      <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center my-6">
        <p className="text-error text-sm font-medium">Gagal memuat profil pemain.</p>
        <button
          onClick={() => navigate(-1)}
          className="mt-4 px-4 py-2 rounded-lg bg-elevated border border-border text-xs text-fg hover:bg-surface transition-colors"
        >
          ← Kembali
        </button>
      </div>
    )
  }

  if (!data) return null

  const { name, tier, games, wins, losses, history } = data
  const safeHistory = history ?? []
  const rankRow = rankPoints?.row
  const winRate = games > 0 ? Math.round((wins / games) * 100) : 0

  const countedPoints = new Map(
    (rankRow?.breakdown ?? []).map((e) => [e.source_id, e.points] as const),
  )

  const medalList = achievements ?? []
  const medalSections = [
    { label: 'Event', rows: medalList.filter((a) => isEventKey(a.key)) },
    { label: 'Standard', rows: medalList.filter((a) => !isEventKey(a.key)) },
  ]

  const ambiguousNames = combineAmbiguous(
    globalAmbiguous,
    collectAmbiguousBaseNames([
      name,
      ...safeHistory.flatMap((h) => [...(h.teammates ?? []), ...(h.opponents ?? [])]),
      ...(stats?.topPartners ?? []).map((p) => p.name),
      ...(stats?.topOpponents ?? []).map((p) => p.name),
      ...(stats?.tournamentStats?.topPartners ?? []).map((p) => p.name),
      ...(stats?.tournamentStats?.topOpponents ?? []).map((p) => p.name),
    ]),
  )

  const matchTotalPages = Math.ceil(safeHistory.length / MATCHES_PER_PAGE)

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
      <div className="flex flex-col gap-4 pb-12">
        {/* Navigation Bar Back link */}
        <div className="flex items-center justify-between">
          <button
            onClick={() => navigate(-1)}
            className="inline-flex items-center gap-1.5 text-xs text-fg-dim hover:text-fg transition-colors active:scale-95 py-1"
          >
            <span aria-hidden="true">←</span>
            <span>Kembali ke Ranking</span>
          </button>
        </div>

        {/* Athlete Hero Card */}
        <div className="bg-surface border border-border-subtle rounded-2xl p-4 sm:p-5 relative overflow-hidden shadow-sm">
          {/* Subtle gold ambient glow */}
          <div className="pointer-events-none absolute -top-14 -right-14 w-44 h-44 rounded-full bg-accent/[0.08] blur-3xl" />

          {/* Profile Header Row */}
          <div className="flex items-center gap-3.5 relative">
            {/* Initials Avatar */}
            <div className="w-13 h-13 rounded-2xl bg-elevated border border-border flex items-center justify-center font-bold text-base font-mono text-accent shadow-inner shrink-0 tracking-wider">
              {getInitials(name)}
            </div>

            {/* Name & Badges */}
            <div className="flex-1 min-w-0">
              <h1 className="text-lg sm:text-xl font-bold text-fg tracking-tight leading-snug truncate">
                <AnnotatedPlayerName name={name} />
              </h1>
              <div className="flex items-center flex-wrap gap-2 mt-1.5">
                {tier && <RatingTierBadge tier={tier} size="md" />}
                {rankRow?.rank ? (
                  <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-mono font-bold bg-accent/15 text-accent border border-accent/30">
                    #{rankRow.rank} Leaderboard
                  </span>
                ) : (
                  <span className="text-xs font-mono text-fg-dim">Unranked</span>
                )}
              </div>
            </div>
          </div>

          {/* Points Highlight Bar */}
          <div className="mt-4 pt-3.5 border-t border-border-subtle flex flex-col sm:flex-row sm:items-center justify-between gap-2.5 relative">
            <div>
              <span className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold block">
                Poin Ranking (12 Minggu)
              </span>
              {rankLoading ? (
                <div className="h-7 w-24 bg-slate-700/60 rounded animate-pulse mt-1" />
              ) : rankRow ? (
                <div className="flex items-baseline gap-2 mt-0.5">
                  <span className="text-2xl sm:text-3xl font-extrabold font-mono text-accent leading-none">
                    {Math.round(rankRow.points).toLocaleString('id-ID')}
                  </span>
                  <span className="text-xs font-sans text-fg-dim">pts</span>
                </div>
              ) : (
                <p className="text-xs font-sans text-fg-dim mt-0.5">
                  Belum ada sesi dinilai dalam 12 minggu terakhir.
                </p>
              )}
            </div>

            {rankRow && (
              <div className="text-left sm:text-right">
                <p className="text-xs font-sans text-fg-dim">
                  <span className="font-semibold text-fg font-mono">{rankRow.counted_entries}</span>
                  {rankRow.entries_available > rankRow.counted_entries ? ` dari ${rankRow.entries_available}` : ''} sesi terbaik dihitung
                </p>
                {rankRow.thin_evidence && (
                  <span className="inline-block mt-1 text-[10px] font-sans text-amber-400 bg-amber-400/10 px-2 py-0.5 rounded-md border border-amber-400/20 font-medium">
                    Bukti masih tipis (&lt;5 sesi)
                  </span>
                )}
              </div>
            )}
          </div>
        </div>

        {/* 3-Column Core Stats Grid */}
        <div className="grid grid-cols-3 gap-2 sm:gap-3">
          {/* Games */}
          <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
            <span className="text-xl sm:text-2xl font-bold font-mono text-fg leading-none">{games}</span>
            <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1.5 font-medium">
              Pertandingan
            </span>
          </div>

          {/* W - L */}
          <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
            <div className="text-xl sm:text-2xl font-bold font-mono leading-none flex items-center justify-center gap-1">
              <span className="text-emerald-400">{wins}W</span>
              <span className="text-fg-dim/40 text-sm font-light">/</span>
              <span className="text-red-400">{losses}L</span>
            </div>
            <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1.5 font-medium">
              Menang - Kalah
            </span>
          </div>

          {/* Win Rate */}
          <div className="bg-surface border border-border-subtle rounded-xl p-3 text-center flex flex-col justify-center">
            <span className="text-xl sm:text-2xl font-bold font-mono text-fg leading-none">
              {games > 0 ? `${winRate}%` : '—'}
            </span>
            {games > 0 && (
              <div className="w-14 mx-auto h-1 bg-ground rounded-full overflow-hidden mt-1.5">
                <div
                  className="h-full bg-emerald-500 rounded-full transition-all"
                  style={{ width: `${Math.min(100, Math.max(0, winRate))}%` }}
                />
              </div>
            )}
            <span className="text-[10px] sm:text-xs font-sans text-fg-dim uppercase tracking-wider mt-1 font-medium">
              Win Rate
            </span>
          </div>
        </div>

        {/* Recent Matches (Scorecard Style) */}
        <div className="flex flex-col gap-2.5">
          <div className="flex items-center justify-between px-1">
            <p className="text-xs font-sans font-semibold text-fg uppercase tracking-wider">
              Pertandingan Terakhir
            </p>
            {safeHistory.length > 0 && (
              <span className="text-[10px] font-mono text-fg-dim">
                {safeHistory.length} total
              </span>
            )}
          </div>

          {safeHistory.length === 0 && (
            <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center">
              <p className="text-fg-dim text-xs font-sans">Belum ada riwayat pertandingan.</p>
            </div>
          )}

          {safeHistory.slice(matchesPage * MATCHES_PER_PAGE, (matchesPage + 1) * MATCHES_PER_PAGE).map((h, i) => {
            const won = h.outcome === 'W'
            const teammates = h.teammates ?? []
            const opponents = h.opponents ?? []
            return (
              <div
                key={i}
                className="bg-surface border border-border-subtle rounded-xl p-3 flex items-center gap-3 transition-colors hover:border-border"
              >
                {/* W/L Badge */}
                <div
                  className={`w-9 h-9 rounded-lg flex items-center justify-center font-bold text-xs shrink-0 ${
                    won
                      ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30'
                      : 'bg-red-500/15 text-red-400 border border-red-500/30'
                  }`}
                >
                  {won ? 'W' : 'L'}
                </div>

                {/* Match participants */}
                <div className="flex-1 min-w-0 flex flex-col justify-center gap-0.5">
                  {/* Teammate */}
                  {teammates.length > 0 && (
                    <p className="text-xs text-fg-dim truncate flex items-center gap-1">
                      <span className="text-fg-dim/60">Bersama</span>
                      {teammates.map((t, tidx) => (
                        <span key={tidx} className="font-medium text-fg inline-flex items-center">
                          <AnnotatedPlayerName name={t} />
                          {tidx < teammates.length - 1 ? ',' : ''}
                        </span>
                      ))}
                    </p>
                  )}

                  {/* Opponents */}
                  <p className="text-sm font-semibold text-fg truncate flex items-center gap-1">
                    <span className="text-xs font-normal text-fg-dim/70">vs</span>
                    {opponents.length > 0 ? (
                      opponents.map((o, oidx) => (
                        <span key={oidx} className="inline-flex items-center">
                          <AnnotatedPlayerName name={o} />
                          {oidx < opponents.length - 1 ? ',' : ''}
                        </span>
                      ))
                    ) : (
                      <span className="text-fg-dim font-normal italic">Lawan tidak tercatat</span>
                    )}
                  </p>

                  {/* Title / Sesi */}
                  {h.title && (
                    <p className="text-[10px] font-sans text-fg-dim/70 truncate">
                      {h.title}
                    </p>
                  )}
                </div>

                {/* Score & Date */}
                <div className="shrink-0 flex flex-col items-end justify-center gap-1">
                  <div className="bg-elevated border border-border px-2.5 py-1 rounded-md text-xs font-mono font-bold tracking-tight text-fg shadow-sm">
                    {h.score_a} - {h.score_b}
                  </div>
                  <span className="text-[10px] font-mono text-fg-dim">
                    {h.date ? h.date.split('-').reverse().join('-') : ''}
                  </span>
                </div>
              </div>
            )
          })}

          {/* Pagination */}
          {matchTotalPages > 1 && (
            <div className="flex items-center justify-between pt-1">
              <button
                onClick={() => setMatchesPage((p) => Math.max(0, p - 1))}
                disabled={matchesPage === 0}
                className="px-3.5 py-1.5 rounded-lg border border-border-subtle bg-surface text-xs font-medium text-fg-dim hover:text-fg hover:border-border disabled:opacity-30 disabled:pointer-events-none active:scale-95 transition-all"
              >
                ← Sebelumnya
              </button>
              <span className="text-xs font-mono text-fg-dim">
                {matchesPage + 1} / {matchTotalPages}
              </span>
              <button
                onClick={() => setMatchesPage((p) => Math.min(matchTotalPages - 1, p + 1))}
                disabled={matchesPage >= matchTotalPages - 1}
                className="px-3.5 py-1.5 rounded-lg border border-border-subtle bg-surface text-xs font-medium text-fg-dim hover:text-fg hover:border-border disabled:opacity-30 disabled:pointer-events-none active:scale-95 transition-all"
              >
                Selanjutnya →
              </button>
            </div>
          )}
        </div>

        {/* Career & Sessions History */}
        <div className="flex flex-col gap-2.5">
          <p className="text-xs font-sans font-semibold text-fg uppercase tracking-wider px-1">
            Rekam Jejak Karir
          </p>
          {stats ? (
            <CareerStats stats={stats} countedPoints={countedPoints} />
          ) : (
            <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center">
              <p className="text-fg-dim text-xs font-sans">Belum ada statistik karir.</p>
            </div>
          )}
        </div>

        {/* Medals */}
        <div className="flex flex-col gap-2.5">
          <p className="text-xs font-sans font-semibold text-fg uppercase tracking-wider px-1">
            Medali & Prestasi
          </p>
          {achLoading && (
            <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center">
              <p className="text-fg-dim text-xs font-sans animate-pulse">Memuat medali…</p>
            </div>
          )}
          {achError && (
            <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center">
              <p className="text-error text-xs font-sans">Gagal memuat medali.</p>
            </div>
          )}
          {!achLoading && !achError && (achievements?.length ?? 0) === 0 && (
            <div className="bg-surface border border-border-subtle rounded-xl p-6 text-center">
              <p className="text-fg-dim text-xs font-sans">
                Belum ada medali. Ikuti sesi pertandingan untuk mengoleksi medali.
              </p>
            </div>
          )}
          {!achLoading && !achError && (achievements?.length ?? 0) > 0 && (
            <div className="bg-surface border border-border-subtle rounded-2xl p-4 sm:p-5 flex flex-col gap-4">
              {medalSections.map(({ label, rows }) =>
                rows.length === 0 ? null : (
                  <div key={label} className="flex flex-col gap-2 border-t border-border-subtle pt-3 first:border-t-0 first:pt-0">
                    <p className="text-[10px] font-sans text-fg-dim uppercase tracking-wider font-semibold">{label}</p>
                    <MedalHoneycomb
                      items={rows.map((a) => (
                        <AchievementBadge
                          key={a.key}
                          icon={medalIcon(a.key)}
                          title={a.title}
                          tierLevel={a.tierLevel}
                          seed={seedFromKey(a.key)}
                          onSelect={() => setSelectedAchievement(a)}
                        />
                      ))}
                    />
                  </div>
                ),
              )}
            </div>
          )}
        </div>

        <AchievementDetailModal achievement={selectedAchievement} onClose={() => setSelectedAchievement(null)} />
      </div>
    </AmbiguousNamesProvider>
  )
}
