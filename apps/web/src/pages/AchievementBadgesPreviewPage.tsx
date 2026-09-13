// src/pages/AchievementBadgesPreviewPage.tsx, pratinjau template badge medal
// (segi enam). Halaman ini hanya untuk melihat bentuk badge; seluruh isi di
// bawah adalah CONTOH, bukan data asli (R-38).
// Tidak ditautkan dari navigasi. Hapus halaman + route-nya kalau badge sudah
// dipakai di halaman rating pemain yang sebenarnya.
import AchievementBadge from '../components/ratings/AchievementBadge'

const MEDAL_TIERS = [1, 2, 3, 4, 5]
const MEDAL_NAMES = ['Bronze', 'Silver', 'Gold', 'Platinum', 'Onyx']
const EVENT_SEEDS = ['majadu-open', 'internal-cup', 'season-2026-1', 'city-league', 'club-night', 'ramadan-cup']

export default function AchievementBadgesPreviewPage() {
  return (
    <div className="flex flex-col gap-5">
      <div className="bg-surface border border-border-subtle rounded-lg px-4 py-3">
        <h2 className="text-sm font-bold text-fg">Medal badge preview</h2>
        <p className="text-[11px] text-fg-dim mt-1 leading-relaxed">
          Everything here is sample content, not real data. All medals share a hexagon silhouette.
          Milestones ramp Bronze..Onyx with five pips; event medals stand apart by their tone and
          monogram.
        </p>
      </div>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Milestone tiers</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-4 flex-wrap">
          {MEDAL_TIERS.map((level, i) => (
            <AchievementBadge
              key={level}
              kind="volume"
              tierLevel={level}
              title={`${MEDAL_NAMES[i]} Games`}
              showDetail
              detail={`${level * 25} games`}
            />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Event medals</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-4 flex-wrap">
          {EVENT_SEEDS.map((seed) => (
            <AchievementBadge
              key={seed}
              kind="season"
              seed={seed}
              monogram={seed.slice(0, 2).toUpperCase()}
              title={seed}
              showDetail
              detail="event medal"
            />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">All kinds &amp; locked state</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-5 flex-wrap">
          <AchievementBadge kind="tournament" title="Tournaments" showDetail detail="shuttlecock" />
          <AchievementBadge kind="attendance" title="Attendance" showDetail detail="check" />
          <AchievementBadge kind="volume" title="Games" showDetail detail="bars" />
          <AchievementBadge kind="social" title="Partners" showDetail detail="two people" />
          <AchievementBadge kind="opponent" title="Opponents" showDetail detail="chevrons" />
          <AchievementBadge kind="season" title="Season" showDetail detail="calendar" />
          <AchievementBadge kind="volume" tierLevel={3} title="Gold Wins" showDetail detail="locked" state="locked" />
          <AchievementBadge kind="tournament" title="Locked event" seed="locked-event" monogram="LE" showDetail detail="locked" state="locked" />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Small size (collection shelf)</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-4 flex items-start gap-5 flex-wrap">
          <AchievementBadge kind="tournament" title="Tournaments" size="sm" />
          {EVENT_SEEDS.slice(0, 3).map((seed) => (
            <AchievementBadge key={seed} kind="season" seed={seed} monogram={seed.slice(0, 2).toUpperCase()} title={seed} size="sm" />
          ))}
          {MEDAL_TIERS.map((level, i) => (
            <AchievementBadge key={level} kind="volume" tierLevel={level} title={MEDAL_NAMES[i]} size="sm" />
          ))}
        </div>
      </section>
    </div>
  )
}
