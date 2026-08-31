// src/pages/admin/AdminSeasonsPage.tsx — Admin: close & start season, list seasons.
import { useMemo, useState } from 'react'
import { useRatingSeasons } from '../../queries/ratings'
import { adminRequest } from '../../queries/admin'
import { t } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'

export default function AdminSeasonsPage() {
  const { data: seasons, refetch } = useRatingSeasons()
  const [seasonDate, setSeasonDate] = useState<string | null>(null)
  const [nowMs] = useState(() => Date.now())

  const openSeason = useMemo(() => (seasons ?? []).find((s) => s.open), [seasons])
  const effectiveSeasonDate = seasonDate ?? openSeason?.start_date ?? new Date().toISOString().slice(0, 10)

  const daySpan = (start: string, end: string | null, now: number) => {
    const s = new Date(start).getTime()
    const e = end ? new Date(end).getTime() : now
    return Math.max(1, Math.round((e - s) / 86400000))
  }

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-2">
            <p className="text-[10px] font-sans text-amber-500/80 uppercase tracking-wider">{t('admin.sectionSeason')}</p>
            <div className="flex flex-wrap gap-2 items-end">
              <label className="flex flex-col gap-1 flex-1 min-w-40">
                <span className="text-[10px] font-sans text-fg-dim">{t('admin.seasonDateLabel')}</span>
                <input
                  type="date"
                  value={effectiveSeasonDate}
                  onChange={(e) => setSeasonDate(e.target.value)}
                  className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm font-sans text-fg scheme-dark focus:border-accent focus:outline-none"
                />
              </label>
              <button
                onClick={() => run(
                  async () => { await adminRequest('POST', '/ratings/season', { startDate: effectiveSeasonDate }) },
                  t('admin.seasonStarted'),
                  () => { setSeasonDate(null); void refetch() },
                )}
                className="px-3 py-2 rounded-lg bg-amber-700/60 text-amber-100 text-sm font-bold"
              >
                Close & Start New
              </button>
            </div>
            <p className="text-[10px] text-fg-dim">{t('admin.seasonHelp')}</p>

            <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
              {(seasons ?? []).map((s) => {
                const endLabel = s.open ? t('admin.active') : s.end_date ?? '—'
                return (
                  <div key={s.id} className="flex flex-wrap items-center gap-x-3 gap-y-0.5 px-3 py-2">
                    <span className={`text-sm font-semibold ${s.open ? 'text-accent' : 'text-fg'}`}>{s.name}</span>
                    <span className={`text-[10px] font-sans ${s.open ? 'text-emerald-400' : 'text-fg-dim'}`}>{s.open ? `● ${t('admin.active')}` : 'closed'}</span>
                    <span className="flex-1 min-w-36 text-[10px] font-sans text-fg-dim">
                      {s.start_date} → {endLabel} · {daySpan(s.start_date, s.end_date, nowMs)} {t('admin.days')}
                    </span>
                    <a href="/ratings" className="text-[10px] font-sans text-accent shrink-0">{t('admin.standings')} →</a>
                  </div>
                )
              })}
            </div>
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
