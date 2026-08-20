// src/pages/admin/AdminPlayersPage.tsx — Admin: add, rename, tier, rebaseline, delete players.
import { useState } from 'react'
import { useListPlayers } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { en } from '../../i18n'
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
  const { data: players, refetch } = useListPlayers()

  const filtered = (players ?? []).filter(
    (p) => !query || p.name.toLowerCase().includes(query.toLowerCase()),
  )
  const slice = filtered.slice(page * PAGE, page * PAGE + PAGE)

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-2">
            <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Player</p>

            {/* Add player standalone */}
            <div className="flex flex-wrap gap-2 items-center bg-surface border border-border-subtle rounded-lg px-3 py-2">
              <input
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                placeholder="Player name"
                className="flex-1 min-w-0 bg-transparent text-sm text-fg placeholder:text-fg-dim/60 focus:outline-none"
              />
              <select
                value={newTier}
                onChange={(e) => setNewTier(e.target.value)}
                className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs font-mono text-fg focus:outline-none"
                aria-label="Tier"
              >
                {TIERS.map((tier) => <option key={tier} value={tier}>Tier {tier}</option>)}
              </select>
              <button
                onClick={() => run(
                  async () => {
                    if (!newName.trim()) throw new Error('Name is required')
                    await adminRequest('POST', '/players', { name: newName.trim(), tier: newTier })
                  },
                  'Player added',
                )}
                className="px-3 py-1.5 rounded-lg bg-accent text-slate-950 text-xs font-bold"
              >
                Add
              </button>
            </div>

            {/* Filter */}
            <input
              value={query}
              onChange={(e) => { setQuery(e.target.value); setPage(0) }}
              placeholder="Filter players by name…"
              className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
            />

            <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No players match.</p>}
              {slice.map((pl) => (
                <div key={pl.playerId ?? pl.name} className="px-3 py-2 flex flex-wrap items-center gap-2">
                  <span className="flex-1 min-w-0 text-sm text-fg truncate">{pl.name}</span>
                  {pl.tierInduk && (
                    <span className="text-[10px] font-mono text-amber-300/80 border border-amber-800/50 rounded px-1.5 py-0.5">tier {pl.tierInduk}</span>
                  )}
                  <ActionButton onClick={() => {
                    const t2 = window.prompt(en.admin.tierPrompt(pl.name), pl.tierInduk ?? 'C')
                    if (t2 && TIERS.includes(t2.toUpperCase())) {
                      run(() => adminRequest('PATCH', `/players/${pl.playerId}/tier`, { tier: t2.toUpperCase() }), 'Tier changed + recalculated')
                    }
                  }}>Tier</ActionButton>
                  <ActionButton onClick={() => {
                    const n2 = window.prompt(en.admin.renamePrompt(pl.name), pl.name)
                    if (n2 && n2.trim() && n2.trim() !== pl.name) {
                      run(
                        () => adminRequest('PATCH', `/players/${pl.playerId}/name`, { name: n2.trim() }),
                        'Name changed (old name kept as alias)',
                        () => refetch(),
                      )
                    }
                  }}>Rename</ActionButton>
                  <ActionButton tone="amber" onClick={() => {
                    if (window.confirm(en.admin.rebaselineConfirm(pl.name))) {
                      run(() => adminRequest('POST', `/ratings/players/${pl.playerId}/rebaseline`), 'Rebaselined — rating set to mid tier')
                    }
                  }}>Rebaseline</ActionButton>
                  <ActionButton tone="red" onClick={() => {
                    if (window.confirm(en.admin.playerDeleteConfirm(pl.name))) {
                      run(() => adminRequest('DELETE', `/players/${pl.playerId}`), 'Player deleted')
                    }
                  }}>Delete</ActionButton>
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
