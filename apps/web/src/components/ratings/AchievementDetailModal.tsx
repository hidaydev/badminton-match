// src/components/ratings/AchievementDetailModal.tsx — popup detail achievement.
// Dipicu dari badge di halaman rating pemain. Pola mengikuti AdminLoginModal:
// backdrop click + Escape untuk menutup, role="dialog", fokus pindah ke tombol
// Close. Menggantikan deskripsi inline supaya rak badge tetap rapi.
import { useEffect } from 'react'
import AchievementBadge from './AchievementBadge'
import { badgeKind, medalTone, monogram, seedFromKey } from '../../utils/achievementBadge'
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
  const meta = a.meta ?? {}
  const tierLevel = a.tierLevel ?? 0
  const tone = medalTone(tierLevel)

  const rows: [string, string][] = []
  if (meta.name && !seedFromKey(a.key)) rows.push(['Tournament', meta.name])
  if (meta.margin) rows.push(['Margin', `${meta.margin} pts`])
  if (meta.partner) rows.push(['Partner', meta.partner])
  if (meta.games) rows.push(['Games together', meta.games])
  if (meta.rating) rows.push(['Rating threshold', meta.rating])
  if (meta.count) rows.push(['Count', meta.count])
  rows.push(['Earned', a.earnedAt])
  if (a.season) rows.push(['Season', a.season])

  const pct = a.nextTarget && a.value != null ? Math.min(100, (a.value / a.nextTarget) * 100) : 100

  return (
    <div
      className="fixed inset-0 z-60 flex items-center justify-center bg-black/60 p-4"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label={`${a.title} details`}
    >
      <div
        className="w-full max-w-xs bg-surface border border-border rounded-xl p-5 flex flex-col items-center gap-3"
        onClick={(e) => e.stopPropagation()}
      >
        <AchievementBadge
          kind={badgeKind(a.kind)}
          tierLevel={tierLevel || undefined}
          seed={seedFromKey(a.key)}
          monogram={monogram(meta.name ?? a.title)}
          title={a.title}
          size="lg"
        />
        {a.detail && <p className="text-xs text-fg-dim text-center">{a.detail}</p>}

        {tierLevel > 0 && a.value != null && (
          <div className="w-full">
            <div className="mb-1 flex justify-between text-[11px] text-fg-dim">
              <span>{a.tierName}</span>
              <span>{a.nextTarget ? `${a.value} / ${a.nextTarget}` : `${a.value} · Max`}</span>
            </div>
            <div className="h-1.5 overflow-hidden rounded-full bg-elevated">
              <div className="h-full rounded-full" style={{ width: `${pct}%`, background: tone }} />
            </div>
          </div>
        )}

        <dl className="mt-1 flex w-full flex-col gap-1">
          {rows.map(([k, v]) => (
            <div key={k} className="flex justify-between gap-3 text-[11px]">
              <dt className="text-fg-dim">{k}</dt>
              <dd className="text-right text-fg">{v}</dd>
            </div>
          ))}
        </dl>
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
