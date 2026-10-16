// src/pages/admin/AdminPlayersPage.tsx — Admin: add, rename, tier, delete players.
import { useState } from 'react'
import { useListPlayers } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { ApiError } from '../../queries/retry'
import { t, en } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'
import Pager from '../../components/admin/Pager'

const TIERS = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']
const PAGE = 10

export default function AdminPlayersPage() {
  const [page, setPage] = useState(0)
  const [query, setQuery] = useState('')
  const [newName, setNewName] = useState('')
  const [newTier, setNewTier] = useState('C')
  // Mode merge: { source } → pilih target dari daftar player lain
  const [mergeSource, setMergeSource] = useState<string | null>(null)
  const { data: players, refetch } = useListPlayers()

  const filtered = (players ?? []).filter(
    (p) => !query || p.name.toLowerCase().includes(query.toLowerCase()),
  )
  const slice = filtered.slice(page * PAGE, page * PAGE + PAGE)

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-3">
            <div className="flex items-center justify-between px-0.5">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionPlayer')}</p>
              <span className="text-xs font-mono text-fg-dim">{filtered.length} players</span>
            </div>

            {/* Add player bar */}
            <div className="flex items-center gap-2 bg-surface border border-border-subtle rounded-xl p-2.5 shadow-xs">
              <input
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                placeholder={t('admin.newPlayerName')}
                className="flex-1 min-w-0 bg-transparent text-sm text-fg placeholder:text-fg-dim/60 focus:outline-none px-1"
              />
              <select
                value={newTier}
                onChange={(e) => setNewTier(e.target.value)}
                className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs font-mono text-fg focus:outline-none cursor-pointer"
                aria-label={t('admin.tierInduk')}
              >
                {TIERS.map((tier) => <option key={tier} value={tier}>Tier {tier}</option>)}
              </select>
              <button
                onClick={() => run(
                  async () => {
                    if (!newName.trim()) throw new Error(t('admin.nameRequired'))
                    await adminRequest('POST', '/players', { name: newName.trim(), tier: newTier })
                  },
                  t('admin.playerAdded'),
                  () => { setNewName(''); refetch() },
                )}
                className="px-3.5 py-1.5 rounded-lg bg-accent text-slate-950 text-xs font-bold hover:brightness-110 active:scale-95 transition-all cursor-pointer shrink-0"
              >
                Add
              </button>
            </div>

            {/* Filter */}
            <input
              value={query}
              onChange={(e) => { setQuery(e.target.value); setPage(0) }}
              placeholder="Filter players by name…"
              className="bg-surface border border-border-subtle rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
            />

            {mergeSource && (
              <div className="flex flex-col gap-1 rounded-xl border border-accent/40 bg-accent/10 px-3.5 py-2.5">
                <p className="text-xs text-accent">
                  Merge mode: select <b>target</b> — all data from <b>{players?.find(p => p.playerId === mergeSource)?.name ?? 'source'}</b> will be merged into target, and source will be deleted.
                </p>
                <button
                  onClick={() => setMergeSource(null)}
                  className="self-start text-[11px] text-accent/80 hover:text-accent underline underline-offset-2 cursor-pointer font-medium"
                >
                  Cancel merge
                </button>
              </div>
            )}

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-sans text-center py-6">No players match.</p>}
              {slice.map((pl) => (
                <div key={pl.playerId ?? pl.name} className="flex items-center justify-between gap-3 px-3.5 py-2.5 hover:bg-elevated/30 transition-colors">
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="text-sm font-medium text-fg truncate">{pl.name}</span>
                    {pl.tierInduk && (
                      <span className="text-[10px] font-mono text-accent bg-accent/10 border border-accent/30 rounded px-1.5 py-0.2">
                        {pl.tierInduk}
                      </span>
                    )}
                    {mergeSource === pl.playerId ? (
                      <span className="text-[10px] font-mono text-accent bg-accent/20 border border-accent/40 rounded px-1.5 py-0.2 font-bold">
                        source
                      </span>
                    ) : null}
                  </div>

                  <div className="flex items-center gap-1.5 shrink-0">
                    {mergeSource && mergeSource !== pl.playerId ? (
                      <ActionButton
                        tone="amber"
                        onClick={() => {
                          const sourceName = players?.find(p => p.playerId === mergeSource)?.name ?? 'source'
                          const targetName = pl.name
                          if (window.confirm(`Merge "${sourceName}" into "${targetName}"?\n\nAll source data will be transferred to target, source deleted, and ratings rebuilt.`)) {
                            run(
                              async () => {
                                await adminRequest('POST', '/players/merge', {
                                  targetPlayerId: pl.playerId,
                                  sourcePlayerId: mergeSource,
                                })
                              },
                              `Merged "${sourceName}" → "${targetName}"`,
                              () => { setMergeSource(null); refetch() },
                            )
                          }
                        }}
                      >
                        Merge →
                      </ActionButton>
                    ) : (
                      <ActionButton
                        tone="amber"
                        onClick={() => { if (pl.playerId) setMergeSource(pl.playerId) }}
                      >
                        Merge
                      </ActionButton>
                    )}
                    <ActionButton onClick={() => {
                      const t2 = window.prompt(en.admin.tierPrompt(pl.name), pl.tierInduk ?? 'C')
                      if (t2 && TIERS.includes(t2.toUpperCase())) {
                        run(
                          () => adminRequest('PATCH', `/players/${pl.playerId}/tier`, { tier: t2.toUpperCase() }),
                          t('admin.tierChanged'),
                          () => refetch(),
                        )
                      }
                    }}>Tier</ActionButton>
                    <ActionButton onClick={() => {
                      const n2 = window.prompt(en.admin.renamePrompt(pl.name), pl.name)
                      if (n2 && n2.trim() && n2.trim() !== pl.name) {
                        run(
                          () => adminRequest('PATCH', `/players/${pl.playerId}/name`, { name: n2.trim() }),
                          t('admin.nameChanged'),
                          () => refetch(),
                        )
                      }
                    }}>Rename</ActionButton>
                    <ActionButton tone="red" onClick={() => {
                      if (!window.confirm(en.admin.playerDeleteConfirm(pl.name))) return
                      run(
                        async () => {
                          try {
                            await adminRequest('DELETE', `/players/${pl.playerId}`)
                          } catch (e) {
                            if (e instanceof ApiError && e.status === 409) {
                              if (!window.confirm(en.admin.playerDeleteForceConfirm(pl.name))) return false
                              await adminRequest('DELETE', `/players/${pl.playerId}?force=true`)
                              return
                            }
                            throw e
                          }
                        },
                        t('admin.playerDeleted'),
                        () => refetch(),
                      )
                    }}>Delete</ActionButton>
                  </div>
                </div>
              ))}
            </div>

            <Pager page={page} total={filtered.length} onPage={setPage} />
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
