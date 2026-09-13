// src/pages/AchievementBadgesPreviewPage.tsx, pratinjau template badge medal
// (segi enam). Halaman ini hanya untuk melihat bentuk badge; seluruh isi di
// bawah adalah CONTOH, bukan data asli (R-38).
// Tidak ditautkan dari navigasi. Hapus halaman + route-nya kalau badge sudah
// dipakai di halaman rating pemain yang sebenarnya.
import AchievementBadge from '../components/ratings/AchievementBadge'
import MedalHoneycomb from '../components/ratings/MedalHoneycomb'
import { MEDAL_TIER_NAMES } from '../config/achievements'
import type { MedalIcon } from '../utils/achievementBadge'

const MEDAL_ICONS: MedalIcon[] = ['check', 'shuttlecock', 'trophy', 'arrow-up', 'flame', 'team', 'versus']
const EVENT_SEEDS = ['majadu-open', 'internal-cup', 'season-2026-1', 'city-league', 'club-night', 'ramadan-cup']

export default function AchievementBadgesPreviewPage() {
  return (
    <div className="flex flex-col gap-5">
      <div className="bg-surface border border-border-subtle rounded-lg px-4 py-3">
        <h2 className="text-sm font-bold text-fg">Medal badge preview</h2>
        <p className="text-[11px] text-fg-dim mt-1 leading-relaxed">
          Everything here is sample content, not real data. All medals share a regular hexagon
          silhouette and carry no text; the icon and colour are the only markers. Milestones ramp
          Bronze..Onyx, event medals get a generated emblem that is unique to their id.
        </p>
      </div>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Milestone tiap tingkat</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-3 flex-wrap">
          {MEDAL_TIER_NAMES.map((_, i) => (
            <AchievementBadge key={i} icon="shuttlecock" tierLevel={i + 1} title={`Games ${MEDAL_TIER_NAMES[i]}`} width={56} />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Ikon tiap medal (harus unik)</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-3 flex-wrap">
          {MEDAL_ICONS.map((icon) => (
            <AchievementBadge key={icon} icon={icon} tierLevel={3} title={icon} width={56} />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Event medals</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-3 flex-wrap">
          {EVENT_SEEDS.map((seed) => (
            <AchievementBadge key={seed} icon="flag" seed={seed} title={seed} width={56} />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Terkunci</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-3 flex-wrap">
          <AchievementBadge icon="trophy" tierLevel={2} title="Locked milestone" state="locked" width={56} />
          <AchievementBadge icon="flag" seed="locked-event" title="Locked event" state="locked" width={56} />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Honeycomb (layout rak)</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5">
          <MedalHoneycomb
            width={56}
            items={[
              'check',
              'shuttlecock',
              'trophy',
              'arrow-up',
              'flame',
              'team',
              'versus',
              'flag',
              'calendar',
              'trophy',
              'check',
            ].map((icon, i) => (
              <AchievementBadge
                key={i}
                icon={icon as MedalIcon}
                tierLevel={i < 7 ? (i % 5) + 1 : undefined}
                seed={i >= 7 ? `ev-${i}` : undefined}
                title={icon}
                width={56}
              />
            ))}
          />
        </div>
      </section>
    </div>
  )
}
