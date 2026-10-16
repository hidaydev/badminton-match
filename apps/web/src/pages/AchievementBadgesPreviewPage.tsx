// src/pages/AchievementBadgesPreviewPage.tsx, pratinjau template badge medal
// (segi enam). Halaman ini untuk melihat bentuk badge dan menguji interaksi popup detail.
// Seluruh isi adalah CONTOH/MOCK, bukan data asli (R-38).

import { useState } from 'react'
import AchievementBadge from '../components/ratings/AchievementBadge'
import AchievementDetailModal from '../components/ratings/AchievementDetailModal'
import MedalHoneycomb from '../components/ratings/MedalHoneycomb'
import { MEDAL_TIER_NAMES } from '../config/achievements'
import type { MedalIcon } from '../utils/achievementBadge'
import type { AchievementRow } from '../queries/endpoints'

const ALL_MEDAL_ICONS: MedalIcon[] = [
  'check',
  'shuttlecock',
  'trophy',
  'flame',
  'team',
  'versus',
  'flag',
  'podium',
  'stairup',
]

const EVENT_SEEDS = [
  'majadu-open',
  'internal-cup',
  'season-2026-1',
  'city-league',
  'club-night',
  'ramadan-cup',
]

export default function AchievementBadgesPreviewPage() {
  const [selected, setSelected] = useState<AchievementRow | null>(null)

  function openMilestone(icon: MedalIcon, tier: number, title: string) {
    const thresholds = [10, 25, 50, 100, 250]
    const currentVal = tier === 1 ? 12 : tier === 2 ? 34 : tier === 3 ? 68 : tier === 4 ? 142 : 280
    setSelected({
      key: `medal:${icon}`,
      kind: 'milestone',
      title: `${title} (${MEDAL_TIER_NAMES[tier - 1]})`,
      detail: `${currentVal} games completed`,
      note: 'Win matches and complete games across official sessions to climb higher tiers.',
      value: currentVal,
      tierLevel: tier,
      tierName: MEDAL_TIER_NAMES[tier - 1],
      nextTarget: tier < 5 ? thresholds[tier] : undefined,
      thresholds,
      earnedAt: '2026-09-12',
    })
  }

  function openEvent(seed: string) {
    setSelected({
      key: `tournament:${seed}`,
      kind: 'tournament',
      title: seed
        .split('-')
        .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
        .join(' '),
      detail: 'Champion - Men Doubles Division A',
      note: 'Awarded for podium finish in the official badminton tournament championship.',
      earnedAt: '2026-10-04',
      meta: { tournamentId: seed },
    })
  }

  return (
    <div className="flex flex-col gap-6 p-1">
      <div className="rounded-xl border border-border-subtle bg-surface px-5 py-4">
        <h2 className="text-base font-bold text-fg">Medal & Achievement System Preview</h2>
        <p className="mt-1 text-xs leading-relaxed text-fg-dim">
          Prestigious metallic hexagonal badges (pointy-top ratio 46.8 x 54). Click any medal below
          to open the tactile Achievement Detail Modal with progress ladders, specular highlights,
          and dual-ring metallic bevels.
        </p>
      </div>

      {/* ── 1. Milestones by Tier ─────────────────────────────────── */}
      <section className="flex flex-col gap-3">
        <p className="px-1 text-[11px] font-semibold uppercase tracking-wider text-fg-dim">
          1. Milestones by Tier (Bronze..Onyx)
        </p>
        <div className="flex flex-wrap items-center gap-4 rounded-xl border border-border-subtle bg-surface px-5 py-5">
          {MEDAL_TIER_NAMES.map((name, i) => (
            <div key={name} className="flex flex-col items-center gap-1.5">
              <AchievementBadge
                icon="trophy"
                tierLevel={i + 1}
                title={`Wins ${name}`}
                width={60}
                onSelect={() => openMilestone('trophy', i + 1, 'Victory Champion')}
              />
              <span className="text-[11px] font-semibold text-fg-dim">{name}</span>
            </div>
          ))}
        </div>
      </section>

      {/* ── 2. All 9 Glyph Icons ───────────────────────────────────── */}
      <section className="flex flex-col gap-3">
        <p className="px-1 text-[11px] font-semibold uppercase tracking-wider text-fg-dim">
          2. Unique Medal Icons (9 Distinct Glyphs)
        </p>
        <div className="flex flex-wrap items-center gap-4 rounded-xl border border-border-subtle bg-surface px-5 py-5">
          {ALL_MEDAL_ICONS.map((icon) => (
            <div key={icon} className="flex flex-col items-center gap-1.5">
              <AchievementBadge
                icon={icon}
                tierLevel={3}
                title={icon}
                width={56}
                onSelect={() => openMilestone(icon, 3, icon.charAt(0).toUpperCase() + icon.slice(1))}
              />
              <span className="font-mono text-[10px] text-fg-dim">{icon}</span>
            </div>
          ))}
        </div>
      </section>

      {/* ── 3. Event & Tournament Seals ─────────────────────────────── */}
      <section className="flex flex-col gap-3">
        <p className="px-1 text-[11px] font-semibold uppercase tracking-wider text-fg-dim">
          3. Event & Tournament Medals (Faceted Dimensional Emblems)
        </p>
        <div className="flex flex-wrap items-center gap-4 rounded-xl border border-border-subtle bg-surface px-5 py-5">
          {EVENT_SEEDS.map((seed) => (
            <div key={seed} className="flex flex-col items-center gap-1.5">
              <AchievementBadge
                icon="flag"
                seed={seed}
                title={seed}
                width={58}
                onSelect={() => openEvent(seed)}
              />
              <span className="font-mono text-[10px] text-fg-dim">{seed}</span>
            </div>
          ))}
        </div>
      </section>

      {/* ── 4. Locked State ────────────────────────────────────────── */}
      <section className="flex flex-col gap-3">
        <p className="px-1 text-[11px] font-semibold uppercase tracking-wider text-fg-dim">
          4. Locked State (Frosted Dark Obsidian Silhouette)
        </p>
        <div className="flex flex-wrap items-center gap-5 rounded-xl border border-border-subtle bg-surface px-5 py-5">
          <div className="flex flex-col items-center gap-1.5">
            <AchievementBadge
              icon="trophy"
              tierLevel={2}
              title="Locked milestone"
              state="locked"
              width={58}
              onSelect={() => openMilestone('trophy', 1, 'Locked Milestone')}
            />
            <span className="text-[10px] text-fg-dim">Locked Milestone</span>
          </div>
          <div className="flex flex-col items-center gap-1.5">
            <AchievementBadge
              icon="flag"
              seed="locked-event"
              title="Locked tournament"
              state="locked"
              width={58}
              onSelect={() => openEvent('locked-tournament')}
            />
            <span className="text-[10px] text-fg-dim">Locked Event</span>
          </div>
        </div>
      </section>

      {/* ── 5. Honeycomb Shelf Layout ───────────────────────────────── */}
      <section className="flex flex-col gap-3">
        <p className="px-1 text-[11px] font-semibold uppercase tracking-wider text-fg-dim">
          5. Honeycomb Shelf Layout (Gapless Packing)
        </p>
        <div className="rounded-xl border border-border-subtle bg-surface px-4 py-6">
          <MedalHoneycomb
            width={60}
            items={ALL_MEDAL_ICONS.map((icon, i) => (
              <AchievementBadge
                key={icon}
                icon={icon}
                tierLevel={i < 7 ? (i % 5) + 1 : undefined}
                seed={i >= 7 ? `event-${i}` : undefined}
                title={icon}
                width={60}
                onSelect={() =>
                  i < 7
                    ? openMilestone(icon, (i % 5) + 1, icon)
                    : openEvent(`event-${i}`)
                }
              />
            ))}
          />
        </div>
      </section>

      {/* Detail Modal saat badge diklik */}
      <AchievementDetailModal
        achievement={selected}
        onClose={() => setSelected(null)}
      />
    </div>
  )
}
