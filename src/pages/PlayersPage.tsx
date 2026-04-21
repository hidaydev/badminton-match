import { useState, useRef, useEffect } from 'react'
import { useStore, type Gender, type Tier, type Player } from '../store'
import { useNavigate } from 'react-router-dom'

function parsePlayerList(raw: string): string[] {
  return raw
    .split('\n')
    .map((line) =>
      line
        .replace(/^\s*\d+[\.\)]\s*/, '')
        .replace(/[\u200B-\u200D\uFEFF\u2060]/g, '')
        .replace(/[\u{1F000}-\u{1FFFF}]/gu, '')
        .replace(/[\u2000-\u206F\u2700-\u27BF]/g, '')
        .replace(/[✅✔☑️\s]+$/, '')
        .trim()
    )
    .filter((name) => name.length > 0)
}

const TIER_COLORS: Record<Tier, string> = {
  1: 'bg-red-500/20 text-red-400 border-red-600',
  2: 'bg-orange-500/20 text-orange-400 border-orange-600',
  3: 'bg-yellow-500/20 text-yellow-400 border-yellow-600',
}
const TIER_LABELS: Record<Tier, string> = { 1: 'A', 2: 'B', 3: 'C' }

function TierBadge({ tier }: { tier: Tier }) {
  return (
    <span className={`inline-flex items-center justify-center w-6 h-6 rounded-md border text-xs font-bold ${TIER_COLORS[tier]}`}>
      {TIER_LABELS[tier]}
    </span>
  )
}

function _GenderBadge({ gender }: { gender: Gender }) {
  return (
    <span className={`text-xs font-semibold px-1.5 py-0.5 rounded ${gender === 'M' ? 'bg-blue-900/50 text-blue-300' : 'bg-pink-900/50 text-pink-300'}`}>
      {gender}
    </span>
  )
}

// ── Inline editable row ───────────────────────────────────────────────────────
function PlayerRow({ player, onRemove }: { player: Player; onRemove: () => void }) {
  const updatePlayer = useStore((s) => s.updatePlayer)
  const [editing, setEditing] = useState(false)
  const [name, setName] = useState(player.name)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (editing) inputRef.current?.focus()
  }, [editing])

  function save() {
    const trimmed = name.trim()
    if (trimmed) updatePlayer(player.id, { name: trimmed })
    else setName(player.name)
    setEditing(false)
  }

  return (
    <div className="flex items-center gap-2 bg-slate-900 border border-slate-800 hover:border-slate-700 rounded-xl px-3 py-2 group transition-colors">
      {/* Avatar */}
      <div className="w-7 h-7 rounded-full bg-slate-700 flex items-center justify-center text-xs font-bold text-slate-300 shrink-0">
        {player.name[0].toUpperCase()}
      </div>

      {/* Name — click to edit */}
      {editing ? (
        <input
          ref={inputRef}
          value={name}
          onChange={(e) => setName(e.target.value)}
          onBlur={save}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') { setName(player.name); setEditing(false) } }}
          className="flex-1 bg-slate-800 border border-indigo-500 rounded-lg px-2 py-1 text-white text-sm focus:outline-none"
        />
      ) : (
        <span
          onClick={() => setEditing(true)}
          className="flex-1 text-white font-medium text-sm cursor-text hover:text-indigo-300 transition-colors"
        >
          {player.name}
        </span>
      )}

      {/* Gender picker */}
      <div className="flex rounded-lg overflow-hidden border border-slate-700">
        {(['M', 'F'] as Gender[]).map((g) => (
          <button
            key={g}
            onClick={() => updatePlayer(player.id, { gender: g })}
            className={`px-2.5 py-1 text-xs font-semibold transition-colors ${
              player.gender === g
                ? g === 'M' ? 'bg-blue-600 text-white' : 'bg-pink-600 text-white'
                : 'text-slate-500 hover:text-slate-300'
            }`}
          >
            {g}
          </button>
        ))}
      </div>

      {/* Tier picker */}
      <div className="flex rounded-lg overflow-hidden border border-slate-700">
        {([1, 2, 3] as Tier[]).map((t) => (
          <button
            key={t}
            onClick={() => updatePlayer(player.id, { tier: t })}
            className={`w-8 py-1 text-xs font-bold transition-colors ${
              player.tier === t
                ? t === 1 ? 'bg-red-500 text-white' : t === 2 ? 'bg-orange-500 text-white' : 'bg-yellow-500 text-slate-900'
                : 'text-slate-500 hover:text-slate-300'
            }`}
          >
            {TIER_LABELS[t]}
          </button>
        ))}
      </div>

      {/* Delete */}
      <button
        onClick={onRemove}
        className="text-slate-600 hover:text-red-400 active:text-red-400 text-sm transition-colors shrink-0 p-1"
      >
        ✕
      </button>
    </div>
  )
}

// ── Add player row ────────────────────────────────────────────────────────────
function AddPlayerRow({ onAdd, onCancel }: { onAdd: (name: string, gender: Gender, tier: Tier) => void; onCancel: () => void }) {
  const [name, setName] = useState('')
  const [gender, setGender] = useState<Gender>('M')
  const [tier, setTier] = useState<Tier>(2)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) return
    onAdd(trimmed, gender, tier)
  }

  return (
    <form onSubmit={submit} className="flex items-center gap-2 bg-slate-900 border border-indigo-600 rounded-xl px-3 py-2">
      <div className="w-7 h-7 rounded-full bg-slate-700 flex items-center justify-center text-slate-500 text-xs shrink-0">
        ?
      </div>
      <input
        autoFocus
        value={name}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Escape') onCancel() }}
        placeholder="Player name"
        className="flex-1 bg-transparent text-white text-sm placeholder-slate-500 focus:outline-none"
      />
      {/* Gender picker */}
      <div className="flex rounded-lg overflow-hidden border border-slate-700">
        {(['M', 'F'] as Gender[]).map((g) => (
          <button
            key={g}
            type="button"
            onClick={() => setGender(g)}
            className={`px-2.5 py-1 text-xs font-semibold transition-colors ${
              gender === g
                ? g === 'M' ? 'bg-blue-600 text-white' : 'bg-pink-600 text-white'
                : 'text-slate-500 hover:text-slate-300'
            }`}
          >
            {g}
          </button>
        ))}
      </div>
      {/* Tier picker */}
      <div className="flex rounded-lg overflow-hidden border border-slate-700">
        {([1, 2, 3] as Tier[]).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTier(t)}
            className={`w-8 py-1 text-xs font-bold transition-colors ${
              tier === t
                ? t === 1 ? 'bg-red-500 text-white' : t === 2 ? 'bg-orange-500 text-white' : 'bg-yellow-500 text-slate-900'
                : 'text-slate-500 hover:text-slate-300'
            }`}
          >
            {TIER_LABELS[t]}
          </button>
        ))}
      </div>
      <button
        type="submit"
        disabled={!name.trim()}
        className="text-indigo-400 hover:text-indigo-300 disabled:opacity-30 text-sm font-medium transition-colors"
      >
        Add
      </button>
      <button type="button" onClick={onCancel} className="text-slate-500 hover:text-slate-300 text-sm transition-colors">
        ✕
      </button>
    </form>
  )
}

// ── Bulk import ───────────────────────────────────────────────────────────────
function BulkImport({ onClose, existingCount, max }: { onClose: () => void; existingCount: number; max: number }) {
  const addPlayers = useStore((s) => s.addPlayers)
  const [text, setText] = useState('')

  const parsed = parsePlayerList(text)
  const available = max - existingCount
  const preview = parsed.slice(0, available)
  const overflow = parsed.length - preview.length

  function handleImport() {
    if (preview.length === 0) return
    addPlayers(preview.map((name) => ({ name, gender: 'M', tier: 2 })))
    onClose()
  }

  return (
    <div className="bg-slate-800 border border-slate-700 rounded-xl p-4 flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-white">Paste player list</span>
        <button onClick={onClose} className="text-slate-500 hover:text-slate-300 text-sm">✕</button>
      </div>
      <textarea
        autoFocus
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={"1. Rakha ✅\n2. Vina ✅\n3. Fakhri ✅"}
        rows={6}
        className="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-white placeholder-slate-600 text-sm font-mono focus:outline-none focus:border-indigo-500 resize-none"
      />
      {preview.length > 0 && (
        <div className="flex flex-col gap-1">
          <span className="text-xs text-slate-400">
            {preview.length} player{preview.length > 1 ? 's' : ''} detected
            {overflow > 0 ? ` (${overflow} skipped — limit reached)` : ''}:
          </span>
          <div className="flex flex-wrap gap-1">
            {preview.map((name) => (
              <span key={name} className="text-xs bg-slate-700 text-slate-200 px-2 py-0.5 rounded-full">{name}</span>
            ))}
          </div>
          <p className="text-xs text-slate-500 mt-1">Gender defaults to M, Tier to A — click to change after import.</p>
        </div>
      )}
      <div className="flex gap-2">
        <button
          disabled={preview.length === 0}
          onClick={handleImport}
          className="flex-1 py-2 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-semibold rounded-lg transition-colors"
        >
          Import {preview.length > 0 ? preview.length : ''} Players
        </button>
        <button onClick={onClose} className="px-4 py-2 text-slate-400 hover:text-slate-200 text-sm rounded-lg hover:bg-slate-700 transition-colors">
          Cancel
        </button>
      </div>
    </div>
  )
}

// ── Page ──────────────────────────────────────────────────────────────────────
export default function PlayersPage() {
  const { players, addPlayer, removePlayer, session } = useStore()
  const [showForm, setShowForm] = useState(false)
  const [showBulk, setShowBulk] = useState(false)
  const navigate = useNavigate()

  const required = session.playerCount
  const isComplete = players.length === required

  function handleAdd(name: string, gender: Gender, tier: Tier) {
    addPlayer({ name, gender, tier })
    setShowForm(false)
  }

  const tierGroups = ([1, 2, 3] as Tier[]).map((t) => ({
    tier: t,
    players: players.filter((p) => p.tier === t),
  }))

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between">
        <div>
          <h2 className="text-2xl font-bold text-white mb-1">Players</h2>
          <p className="text-slate-400 text-sm">Click name to rename · Click badge to toggle gender/tier.</p>
        </div>
        <span className={`text-sm font-semibold px-3 py-1 rounded-full border ${
          isComplete
            ? 'text-emerald-400 border-emerald-700 bg-emerald-900/30'
            : players.length > required
            ? 'text-red-400 border-red-700 bg-red-900/30'
            : 'text-slate-400 border-slate-700 bg-slate-800'
        }`}>
          {players.length}/{required}
        </span>
      </div>

      {/* Bulk import panel */}
      {showBulk && (
        <BulkImport onClose={() => setShowBulk(false)} existingCount={players.length} max={required} />
      )}

      {/* Player list grouped by tier */}
      {players.length > 0 && (
        <div className="flex flex-col gap-4">
          {tierGroups.map(({ tier, players: group }) =>
            group.length === 0 ? null : (
              <div key={tier}>
                <div className="flex items-center gap-2 mb-2">
                  <TierBadge tier={tier} />
                  <span className="text-xs text-slate-500">
                    {tier === 1 ? 'Senior' : tier === 2 ? 'Intermediate' : 'Beginner'}
                  </span>
                </div>
                <div className="flex flex-col gap-1.5">
                  {group.map((player) => (
                    <PlayerRow key={player.id} player={player} onRemove={() => removePlayer(player.id)} />
                  ))}
                </div>
              </div>
            )
          )}
        </div>
      )}

      {/* Add row */}
      {showForm ? (
        <AddPlayerRow onAdd={handleAdd} onCancel={() => setShowForm(false)} />
      ) : (
        <div className="flex gap-2">
          <button
            disabled={players.length >= required}
            onClick={() => setShowForm(true)}
            className="flex-1 py-2.5 border-2 border-dashed border-slate-700 hover:border-indigo-500 disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-indigo-400 rounded-xl text-sm font-medium transition-colors"
          >
            + Add Player
          </button>
          <button
            disabled={players.length >= required}
            onClick={() => setShowBulk((v) => !v)}
            className="py-2.5 px-4 border-2 border-dashed border-slate-700 hover:border-emerald-500 disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-emerald-400 rounded-xl text-sm font-medium transition-colors"
            title="Bulk import from text"
          >
            📋 Bulk
          </button>
        </div>
      )}

      {players.length === 0 && !showForm && !showBulk && (
        <div className="text-center py-12 text-slate-500">
          <div className="text-4xl mb-3">👥</div>
          <p>No players yet. Add {required} players to continue.</p>
        </div>
      )}

      {/* Progress hint */}
      {players.length > 0 && !isComplete && (
        <p className="text-xs text-center text-slate-500">
          {players.length < required
            ? `${required - players.length} more player${required - players.length > 1 ? 's' : ''} needed`
            : `${players.length - required} too many — remove ${players.length - required} to match session`}
        </p>
      )}

      <button
        disabled={!isComplete || !session.locked}
        onClick={() => navigate('/constraints')}
        className="w-full py-2.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold rounded-xl transition-colors mt-2"
      >
        {!session.locked
          ? 'Go to Setup to start session'
          : isComplete
          ? 'Next: Constraints →'
          : `Add players (${players.length}/${required})`}
      </button>
    </div>
  )
}
