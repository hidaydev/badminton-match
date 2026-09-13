// src/pages/AchievementBadgesPreviewPage.tsx, pratinjau template badge
// achievement (shield/patch). Halaman ini hanya untuk melihat bentuk badge;
// seluruh isi di bawah adalah CONTOH, bukan data asli (R-38).
// Tidak ditautkan dari navigasi. Hapus halaman + route-nya kalau badge sudah
// dipakai di halaman rating pemain yang sebenarnya.
import AchievementBadge from '../components/ratings/AchievementBadge'
import type { RatingTier } from '../config/ratingTiers'

const TIERS: RatingTier[] = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']

export default function AchievementBadgesPreviewPage() {
  return (
    <div className="flex flex-col gap-5">
      <div className="bg-surface border border-border-subtle rounded-lg px-4 py-3">
        <h2 className="text-sm font-bold text-fg">Preview template badge</h2>
        <p className="text-[11px] text-fg-dim mt-1 leading-relaxed">
          Isi di halaman ini contoh, bukan data asli. Dua jenis achievement: keikutsertaan turnamen
          (glyph shuttlecock) dan breakthrough tier. Badge tier memakai pips dan warna tepi yang
          menguat dari bronze ke gold sesuai tingkat.
        </p>
      </div>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Ikut turnamen</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-6 flex-wrap">
          <AchievementBadge kind="tournament" title="Turnamen Contoh" detail="Contoh, 2026" />
          <AchievementBadge kind="tournament" title="Turnamen Contoh 2" detail="Belum terbuka" state="locked" />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Breakthrough tier, semua tingkat</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-4 flex-wrap">
          {TIERS.map((t) => (
            <AchievementBadge key={t} kind="tier" tier={t} title={`Naik ke ${t}`} detail="Contoh" />
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Terkunci</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-6 flex-wrap">
          <AchievementBadge kind="tier" tier="A+" title="Naik ke A+" detail="Belum terbuka" state="locked" />
          <AchievementBadge kind="tournament" title="Turnamen Contoh 3" detail="Belum terbuka" state="locked" />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Semua jenis achievement</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-5 flex items-start gap-5 flex-wrap">
          <AchievementBadge kind="tournament" title="Turnamen" detail="shuttlecock" />
          <AchievementBadge kind="attendance" title="Kehadiran" detail="check" />
          <AchievementBadge kind="volume" title="Volume" detail="bar naik" />
          <AchievementBadge kind="social" title="Partner" detail="dua orang" />
          <AchievementBadge kind="opponent" title="Lawan" detail="chevron hadap" />
          <AchievementBadge kind="season" title="Season" detail="kalender" />
          <AchievementBadge kind="tier" tier="B+" title="Naik ke B+" detail="chevron + pips" />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-[10px] text-fg-dim uppercase tracking-wider px-1">Ukuran kecil (rak koleksi)</p>
        <div className="bg-surface border border-border-subtle rounded-lg px-4 py-4 flex items-start gap-5 flex-wrap">
          <AchievementBadge kind="tournament" title="Turnamen Contoh" size="sm" />
          {TIERS.slice(2).map((t) => (
            <AchievementBadge key={t} kind="tier" tier={t} title={`Naik ke ${t}`} size="sm" />
          ))}
        </div>
      </section>
    </div>
  )
}
