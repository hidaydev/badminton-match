// src/pages/TournamentListPage.tsx: list of all tournaments (classic & team cup).
import { useState, useMemo } from 'react'
import { useNavigate } from '../router'
import { useListTournaments } from '../queries'
import { useAdmin } from '../context/AdminContext'
import { t } from '../../i18n'
import Icon from '../components/Icon'
import { Card } from '../../components/Card'
import { EmptyState } from '../../components/EmptyState'

const MONTH_NAMES = ['', 'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

export default function TournamentListPage() {
  const navigate = useNavigate()
  // Only a host or admin may create a tournament; members browse the list.
  const { isAdmin } = useAdmin()
  const [selectedFormat, setSelectedFormat] = useState<'all' | 'team' | 'classic'>('all')
  const { data: tournaments = [], isLoading, isError } = useListTournaments()

  const filtered = useMemo(() => {
    if (selectedFormat === 'all') return tournaments
    return tournaments.filter((tItem) => tItem.format === selectedFormat)
  }, [tournaments, selectedFormat])

  return (
    <div className="flex flex-col gap-3">
      {/* Header */}
      <div className="flex items-center justify-between gap-2">
        <div>
          <h1 className="text-lg font-bold text-fg">{t('tournaments.title')}</h1>
          <span className="text-xs font-mono text-fg-dim font-medium">
            {filtered.length} {t('common.total')}
          </span>
        </div>
        {isAdmin && (
          <button
            onClick={() => navigate('/tournaments/new')}
            className="px-3.5 py-1.5 rounded-lg bg-accent text-slate-950 text-xs font-bold hover:brightness-110 active:scale-[0.98] transition-[filter,transform] shadow-sm hit44"
          >
            {t('tournaments.newButton')}
          </button>
        )}
      </div>

      {/* Filter Format Chips */}
      <div className="flex items-center gap-1.5 overflow-x-auto pb-0.5 text-xs">
        {(['all', 'team', 'classic'] as const).map((fmt) => {
          const isSelected = selectedFormat === fmt
          const label = fmt === 'all'
            ? t('common.all')
            : fmt === 'team'
              ? t('tournaments.formatTeam')
              : t('tournaments.formatClassic')
          return (
            <button
              key={fmt}
              type="button"
              onClick={() => setSelectedFormat(fmt)}
              className={`hit44 shrink-0 px-2.5 py-1 rounded-full font-medium transition-colors border ${
                isSelected
                  ? 'bg-accent/20 text-accent border-accent/60 font-semibold'
                  : 'bg-surface text-fg-dim border-border-subtle hover:text-fg hover:border-border'
              }`}
            >
              {label}
            </button>
          )
        })}
      </div>

      {isError && <p className="text-error text-sm">{t('tournaments.loadFailed')}</p>}

      {!isError && isLoading && (
        <div className="bg-surface border border-border-subtle rounded-xl overflow-hidden divide-y divide-border-subtle animate-pulse">
          {[0, 1, 2].map((i) => (
            <div key={i} className="flex items-center gap-3.5 px-3.5 py-3">
              <div className="w-11 h-11 bg-slate-700/60 rounded-lg shrink-0" />
              <div className="flex-1 space-y-2">
                <div className="h-4 w-3/4 bg-slate-700/60 rounded" />
                <div className="h-3 w-1/4 bg-slate-700/60 rounded" />
              </div>
              <div className="w-16 h-6 bg-slate-700/60 rounded shrink-0" />
            </div>
          ))}
        </div>
      )}

      {!isError && !isLoading && filtered.length === 0 && (
        <Card radius="xl">
          <EmptyState title={t('tournaments.noTournamentsYet')} />
        </Card>
      )}

      {!isError && !isLoading && filtered.length > 0 && (
        <Card variant="flush" radius="xl" className="divide-y divide-border-subtle shadow-sm">
          {filtered.map((tItem) => {
            const isTeam = tItem.format === 'team'
            const dateParts = tItem.date ? tItem.date.split('-') : []
            const year = dateParts[0]
            const monthNum = parseInt(dateParts[1] || '0', 10)
            const day = dateParts[2] || '—'
            const month = MONTH_NAMES[monthNum] || ''

            return (
              <button
                key={tItem.id}
                onClick={() => navigate(`/tournaments/${tItem.id}`)}
                className="w-full flex items-center gap-3.5 px-3.5 py-3 hover:bg-elevated text-left transition-colors active:bg-elevated/70 hit44"
              >
                {/* Date Badge */}
                <div className="w-11 h-11 rounded-lg bg-elevated border border-border flex flex-col items-center justify-center shrink-0">
                  <span className="text-sm font-bold font-mono text-fg leading-none">{day}</span>
                  <span className="text-[11px] font-mono font-semibold text-accent uppercase leading-none mt-1">
                    {month}
                  </span>
                </div>

                {/* Name & Format */}
                <div className="flex-1 min-w-0 flex flex-col justify-center gap-1">
                  <span className="text-sm font-semibold text-fg truncate">
                    {tItem.name || 'Untitled Tournament'}
                  </span>
                  <div className="flex items-center gap-2">
                    <span
                      className={`text-[10px] font-mono font-medium px-1.5 py-0.5 rounded border leading-none ${
                        isTeam
                          ? 'text-accent bg-accent/10 border-accent/25'
                          : 'text-sky-400 bg-sky-500/10 border-sky-500/25'
                      }`}
                    >
                      {isTeam ? t('tournaments.formatTeam') : t('tournaments.formatClassic')}
                    </span>
                    <span className="text-[10px] font-mono text-fg-dim">
                      {year}
                    </span>
                  </div>
                </div>

                {/* Arrow */}
                <div className="shrink-0 flex items-center">
                  <Icon name="chevron-right" size={16} className="text-fg-dim/40" />
                </div>
              </button>
            )
          })}
        </Card>
      )}
    </div>
  )
}
