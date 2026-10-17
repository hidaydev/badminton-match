// src/components/ratings/AchievementDetailModal.tsx — popup detail medal prestisius.
// Dipicu dari klik/tap badge medal pada rak profil atau pratinjau.
//
// Fitur:
// - Showcase medal besar (width 96px) di atas panggung radial ambient glow.
// - Tier pill badge bernuansa metalik (Bronze, Silver, Gold, Platinum, Onyx, atau Tournament).
// - Tangga progres 5-tingkat dengan rel penghubung (progress track), status earned/locked,
//   dan indikator tier saat ini.
// - Bar progres ke tier berikutnya jika milestone belum maksimal.
// - Aksesibilitas keyboard (Escape & fokus awal tombol Close).

import { useEffect } from 'react'
import AchievementBadge from './AchievementBadge'
import {
  eventTone,
  isEventKey,
  medalIcon,
  seedFromKey,
} from '../../utils/achievementBadge'
import {
  getEventMedalStyle,
  MEDAL_TIER_NAMES,
  MEDAL_TIER_STYLES,
} from '../../config/achievements'
import type { AchievementRow } from '../../queries/endpoints'

interface AchievementDetailModalProps {
  achievement: AchievementRow | null
  onClose: () => void
}

export default function AchievementDetailModal({
  achievement,
  onClose,
}: AchievementDetailModalProps) {
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
  const isEvent = isEventKey(a.key)
  const seed = seedFromKey(a.key)

  // Style untuk showcase header
  const tierIdx = Math.max(0, Math.min(MEDAL_TIER_STYLES.length - 1, tierLevel - 1))
  const currentTierStyle = isEvent && seed
    ? getEventMedalStyle(eventTone(seed))
    : isMilestone
      ? MEDAL_TIER_STYLES[tierIdx]
      : MEDAL_TIER_STYLES[2]

  // Hitung progres ke tier berikutnya jika ada
  const nextTarget = a.nextTarget ?? (tierLevel < thresholds.length ? thresholds[tierLevel] : null)
  const prevTarget = tierLevel > 1 && thresholds[tierLevel - 2] ? thresholds[tierLevel - 2] : 0
  const currentValue = a.value ?? 0
  let progressPercent = 0
  if (nextTarget && nextTarget > prevTarget && currentValue >= prevTarget) {
    progressPercent = Math.min(
      100,
      Math.max(0, Math.round(((currentValue - prevTarget) / (nextTarget - prevTarget)) * 100)),
    )
  }

  return (
    <div
      className="fixed inset-0 z-60 flex items-center justify-center bg-black/75 backdrop-blur-sm p-4 animate-[fadeInScale_0.15s_ease-out]"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label={`${a.title} details`}
    >
      <div
        className="relative flex w-full max-w-sm flex-col overflow-hidden rounded-2xl border border-border/80 bg-surface shadow-2xl"
        onClick={(e) => e.stopPropagation()}
        style={{
          ['--modal-glow' as string]: currentTierStyle.glow,
        }}
      >
        {/* Ambient Top Glow Panggung */}
        <div
          className="pointer-events-none absolute -top-12 left-1/2 h-44 w-72 -translate-x-1/2 rounded-full opacity-35 blur-2xl"
          style={{ background: currentTierStyle.glow }}
        />

        {/* ── Showcase Kartu Medal Utama ─────────────────────────── */}
        <div className="relative flex flex-col items-center px-6 pt-7 pb-4 text-center">
          <div className="mb-3 transition-transform hover:scale-105 duration-300">
            <AchievementBadge
              icon={medalIcon(a.key)}
              tierLevel={tierLevel || undefined}
              seed={seed}
              title={a.title}
              width={96}
            />
          </div>

          {/* Tier Name Pill */}
          {isMilestone ? (
            <div
              className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-0.5 text-[10px] font-bold tracking-wider uppercase ${currentTierStyle.pillBorder} ${currentTierStyle.pillBg} ${currentTierStyle.pillText}`}
            >
              <span className="text-[11px] leading-none">★</span>
              <span>
                {MEDAL_TIER_NAMES[tierIdx]} Tier ({tierLevel}/{thresholds.length})
              </span>
            </div>
          ) : isEvent ? (
            <div className="inline-flex items-center gap-1.5 rounded-full border border-border bg-elevated px-3 py-0.5 text-[10px] font-bold tracking-wider uppercase text-fg">
              <span className="text-accent text-[11px] leading-none">◆</span>
              <span>Tournament Medal</span>
            </div>
          ) : (
            <div className="inline-flex items-center gap-1.5 rounded-full border border-border bg-elevated px-3 py-0.5 text-[10px] font-bold tracking-wider uppercase text-fg">
              <span>Achievement</span>
            </div>
          )}

          <h3 className="mt-2 text-base font-bold text-fg">{a.title}</h3>

          {a.detail && (
            <p className="mt-0.5 text-xs font-semibold text-accent">{a.detail}</p>
          )}

          {a.note && (
            <p className="mt-1 text-xs leading-relaxed text-fg-dim">{a.note}</p>
          )}
        </div>

        {/* ── Tangga Tingkat (Milestone Ladder) ─────────────────── */}
        {isMilestone ? (
          <div className="flex flex-col gap-3 border-t border-border-subtle bg-surface/50 px-5 pt-4 pb-5">
            <div className="flex items-center justify-between text-[10px] font-semibold uppercase tracking-wider text-fg-dim">
              <span>Milestone Ladder</span>
              <span className="text-fg">
                {tierLevel} of {thresholds.length} completed
              </span>
            </div>

            {/* Rel Horizontal Menghubungkan 5 Tingkat */}
            <div className="relative pt-1 pb-1">
              {/* Garis Track Latar Belakang */}
              <div className="absolute top-[22px] inset-x-5 h-0.5 bg-border-subtle" />
              {/* Garis Track Selesai (Gradien Emas/Logam) */}
              {tierLevel > 1 && (
                <div
                  className="absolute top-[22px] left-5 h-0.5 bg-gradient-to-r from-amber-600 via-yellow-400 to-cyan-400"
                  style={{
                    width: `calc(${((tierLevel - 1) / (thresholds.length - 1)) * 100}% - 10px)`,
                  }}
                />
              )}

              <div className="relative grid grid-cols-5 gap-1.5">
                {thresholds.map((target, i) => {
                  const level = i + 1
                  const achieved = level <= tierLevel
                  const isCurrent = level === tierLevel
                  const tierName = MEDAL_TIER_NAMES[i]
                  const label = a.key === 'medal:rank' ? `#${target}` : `${target}`

                  return (
                    <div
                      key={level}
                      className="group flex flex-col items-center gap-1.5"
                      aria-label={`${tierName} ${label}`}
                    >
                      <div className="relative">
                        <AchievementBadge
                          icon={medalIcon(a.key)}
                          tierLevel={level}
                          title={`${tierName} ${label}`}
                          state={achieved ? 'earned' : 'locked'}
                          width={44}
                        />
                        {/* Indikator tier aktif saat ini */}
                        {isCurrent && (
                          <div className="absolute -bottom-1 left-1/2 h-1.5 w-1.5 -translate-x-1/2 rounded-full bg-accent ring-2 ring-surface" />
                        )}
                      </div>

                      <div className="flex flex-col items-center">
                        <span
                          className={`text-[9px] font-medium leading-none ${achieved ? 'text-fg' : 'text-fg-dim/60'}`}
                        >
                          {tierName}
                        </span>
                        <span
                          className={`mt-0.5 text-[10px] font-bold leading-tight ${achieved ? 'text-fg' : 'text-fg-dim/50'}`}
                        >
                          {label}
                        </span>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>

            {/* Progress Bar ke Tier Berikutnya jika belum Max */}
            {tierLevel < thresholds.length && nextTarget && a.value != null && (
              <div className="mt-1 rounded-lg border border-border-subtle bg-ground/40 p-2.5">
                <div className="flex items-center justify-between text-[10px]">
                  <span className="text-fg-dim">
                    Next:{' '}
                    <span className="font-semibold text-fg">
                      {MEDAL_TIER_NAMES[tierLevel]} ({a.key === 'medal:rank' ? `#${nextTarget}` : nextTarget})
                    </span>
                  </span>
                  <span className="font-mono text-xs font-semibold text-accent">
                    {a.value} / {nextTarget}
                  </span>
                </div>
                <div className="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-elevated">
                  <div
                    className="h-full rounded-full bg-gradient-to-r from-amber-500 to-yellow-400 transition-all duration-500"
                    style={{ width: `${progressPercent}%` }}
                  />
                </div>
              </div>
            )}
          </div>
        ) : (
          /* Metadata untuk Event Medals */
          <div className="flex flex-col gap-2 border-t border-border-subtle bg-surface/50 px-5 pt-4 pb-5">
            <dl className="flex flex-col gap-1.5">
              <div className="flex justify-between gap-3 text-xs">
                <dt className="text-fg-dim">Earned On</dt>
                <dd className="font-medium text-fg">{a.earnedAt}</dd>
              </div>
              {seed && (
                <div className="flex justify-between gap-3 text-xs">
                  <dt className="text-fg-dim">Tournament ID</dt>
                  <dd className="font-mono text-[11px] text-fg-dim">{seed}</dd>
                </div>
              )}
            </dl>
          </div>
        )}
      </div>
    </div>
  )
}
