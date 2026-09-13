// src/components/ratings/AchievementDetailModal.tsx — popup detail medal.
// Dipicu dari badge di rak (badge sendiri tanpa teks). Pola mengikuti
// AdminLoginModal: backdrop click + Escape untuk menutup, role="dialog", fokus
// pindah ke tombol Close.
//
// Isi popup: ikon + nama medal + deskripsi singkat + angka pencapaian sekarang,
// lalu tangga tingkat (Bronze..Onyx) dengan ambangnya. Event medal tidak
// bertingkat, jadi yang tampil hanya keterangan event-nya.
import { useEffect } from 'react'
import AchievementBadge from './AchievementBadge'
import { medalIcon, seedFromKey } from '../../utils/achievementBadge'
import { MEDAL_TIER_NAMES } from '../../config/achievements'
import type { AchievementRow } from '../../queries/endpoints'

interface AchievementDetailModalProps {
  achievement: AchievementRow | null
  onClose: () => void
}

export default function AchievementDetailModal({ achievement, onClose }: AchievementDetailModalProps) {
  useEffect(() => {
    if (!achievement) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [achievement, onClose])

  if (!achievement) return null
  const a = achievement
  const tierLevel = a.tierLevel ?? 0
  const thresholds = a.thresholds ?? []
  const isMilestone = thresholds.length > 0 && tierLevel > 0

  const rows: [string, string][] = [['Earned', a.earnedAt]]
  if (a.season) rows.unshift(['Season', a.season])

  return (
    <div
      className="fixed inset-0 z-60 flex items-center justify-center bg-black/60 p-4"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label={`${a.title} details`}
    >
      <div
        className="flex w-full max-w-xs flex-col gap-3 rounded-xl border border-border bg-surface p-5"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-4">
          <AchievementBadge
            icon={medalIcon(a.key)}
            tierLevel={tierLevel || undefined}
            seed={seedFromKey(a.key)}
            title={a.title}
            width={84}
          />
          <div className="min-w-0 flex-1">
            <p className="text-sm font-bold text-fg">{a.title}</p>
            {a.note && <p className="mt-0.5 text-xs text-fg-dim">{a.note}</p>}
            {a.value != null && <p className="mt-1 text-xs text-fg">{a.detail}</p>}
          </div>
        </div>

        {isMilestone ? (
          <div className="mt-1 w-full border-t border-border-subtle pt-3">
            <p className="mb-2 text-[10px] uppercase tracking-wider text-fg-dim">Tiers</p>
            <div className="grid grid-cols-5 gap-1">
              {thresholds.map((target, i) => {
                const level = i + 1
                const achieved = level <= tierLevel
                return (
                  <div key={level} className="flex flex-col items-center gap-1" aria-label={`${MEDAL_TIER_NAMES[i]} ${target}`}>
                    <AchievementBadge
                      icon={medalIcon(a.key)}
                      tierLevel={level}
                      title={`${MEDAL_TIER_NAMES[i]} ${target}`}
                      state={achieved ? 'earned' : 'locked'}
                      width={40}
                    />
                    <span className={`text-[10px] leading-tight ${achieved ? 'text-fg' : 'text-fg-dim'}`}>{target}</span>
                  </div>
                )
              })}
            </div>
          </div>
        ) : (
          <dl className="flex w-full flex-col gap-1 border-t border-border-subtle pt-3">
            {rows.map(([k, v]) => (
              <div key={k} className="flex justify-between gap-3 text-[11px]">
                <dt className="text-fg-dim">{k}</dt>
                <dd className="text-right text-fg">{v}</dd>
              </div>
            ))}
          </dl>
        )}

        <button
          type="button"
          autoFocus
          onClick={onClose}
          className="mt-1 w-full rounded-lg bg-elevated py-2 text-sm font-semibold text-fg transition-colors hover:bg-border/70"
        >
          Close
        </button>
      </div>
    </div>
  )
}
