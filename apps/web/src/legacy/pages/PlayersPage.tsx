import { useState, useRef, useEffect, useMemo } from 'react'
import type { Gender, Tier, Player } from '../types'
import { useStore } from '../store'
import { useNavigate } from '../router'
import { isPlaceholderName } from '../utils/placeholders'
import { useListPlayers } from '../queries'
import { t } from '../../i18n'

function parsePlayerList(raw: string): string[] {
  return raw
    .split('\n')
    .map((line) =>
      line
        .replace(/[\u200B-\u200D\uFEFF\u2060]/g, '')
        .replace(/[\u{1F000}-\u{1FFFF}]/gu, '')
        .replace(/[\u2000-\u206F]/gu, '')
        .replace(/[\u2700-\u27BF]/gu, '')
        .replace(/^\s*\d+\s*[.)]\s*/, '')
        .replace(/(?:✅|✔|☑️|\s)+$/gu, '')
        .trim()
    )
    .filter((name) => name.length > 0)
}

import { TIER_LABELS, TIER_BADGE_COLORS, TIER_ACTIVE, TIER_NAMES, TIERS } from '../config/tiers'
import Icon from '../components/Icon'
import { Button, IconButton } from '../../components/Button'
import { Chip } from '../../components/Chip'
import { EmptyState } from '../../components/EmptyState'

// Convert canonical tier string (D..A+) to numeric (1..8)
function tierStringToNumber(tier: string): Tier {
  const map: Record<string, Tier> = { 'D': 1, 'D+': 2, 'C': 3, 'C+': 4, 'B': 5, 'B+': 6, 'A': 7, 'A+': 8 }
  return map[tier.toUpperCase()] ?? 2
}

function TierBadge({ tier }: { tier: Tier }) {
  return (
    <span className={`inline-flex items-center justify-center w-6 h-6 rounded-lg border text-xs font-bold ${TIER_BADGE_COLORS[tier] ?? TIER_BADGE_COLORS[3]}`}>
      {TIER_LABELS[tier] ?? tier}
    </span>
  )
}

// ── Shared pickers ────────────────────────────────────────────────────────────
function GenderToggle({ value, onChange }: { value: Gender; onChange: (g: Gender) => void }) {
  return (
    <div className="flex shrink-0 gap-1">
      {(['M', 'F'] as Gender[]).map((g) => (
        <Chip key={g} size="sm" selected={value === g} onClick={() => onChange(g)}>
          {g}
        </Chip>
      ))}
    </div>
  )
}

function TierToggle({ value, onChange }: { value: Tier; onChange: (t: Tier) => void }) {
  return (
    // Eight chips do not fit one line at 360 with the name and the remove
    // button, so the group takes its own line below `sm` and wraps there.
    <div className="flex w-full flex-wrap gap-1 sm:w-auto sm:flex-nowrap">
      {TIERS.map((t) => (
        <Chip key={t} size="sm" selected={value === t} onClick={() => onChange(t)}>
          {TIER_LABELS[t]}
        </Chip>
      ))}
    </div>
  )
}

// ── Inline editable row ───────────────────────────────────────────────────────
function PlayerRow({ player, onRemove, isRegistered, ambiguousMatches }: { 
  player: Player; 
  onRemove: () => void;
  isRegistered: boolean;
  ambiguousMatches?: Array<{ name: string; gender: Gender; tier: Tier }>;
}) {
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
    <div className="flex flex-col gap-1.5">
      <div className="flex flex-wrap items-center gap-1.5 sm:gap-2 bg-surface border border-border-subtle hover:border-slate-700 rounded-xl px-2.5 py-2 group transition-colors">
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
            className="flex-1 bg-slate-800 border border-indigo-500 rounded-lg px-2 py-1 text-white text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          />
        ) : (
          <span
            onClick={() => setEditing(true)}
            className="flex-1 text-white font-medium text-sm cursor-text hover:text-indigo-300 transition-colors"
          >
            {player.name}
            {isPlaceholderName(player.name) && (
              <span className="ml-2 text-[11px] font-bold text-amber-400/90 bg-amber-900/40 border border-amber-700/50 rounded px-1 py-0.5 label-meta">
                tbd
              </span>
            )}
          </span>
        )}

        {/* Gender picker */}
        <GenderToggle value={player.gender} onChange={(g) => updatePlayer(player.id, { gender: g })} />

        {/* Tier — read-only badge untuk registered player, picker untuk new player */}
        {isRegistered ? (
          <span className={`inline-flex items-center justify-center min-w-8 h-8 text-xs font-bold rounded-lg ${TIER_ACTIVE[player.tier]}`}>
            {TIER_LABELS[player.tier]}
          </span>
        ) : (
          <TierToggle value={player.tier} onChange={(t) => updatePlayer(player.id, { tier: t })} />
        )}

        {/* Delete */}
        <IconButton
          label={t('wizard.players.remove')}
          size="sm"
          onClick={onRemove}
          className="text-fg-dim hover:text-error"
        >
          ✕
        </IconButton>
      </div>

      {ambiguousMatches && ambiguousMatches.length > 0 && (
        <div className="bg-amber-950/70 border border-amber-600/70 rounded-xl p-2.5 flex flex-col gap-1.5 text-xs ml-1 mr-1">
          <span className="text-amber-300 font-semibold flex items-center gap-1">
            ⚠️ Name &ldquo;{player.name}&rdquo; is ambiguous ({ambiguousMatches.length} registered players found):
          </span>
          <div className="flex flex-wrap gap-1.5">
            {ambiguousMatches.map((m) => (
              <Button
                key={m.name}
                variant="secondary"
                size="sm"
                onClick={() => {
                  updatePlayer(player.id, { name: m.name, gender: m.gender, tier: m.tier })
                  setName(m.name)
                }}
                className="gap-1.5 font-normal"
              >
                <span>{m.name}</span>
                <span className="text-[10px] text-fg-dim">({TIER_LABELS[m.tier]} · {m.gender})</span>
              </Button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

// ── Add player row ────────────────────────────────────────────────────────────
function AddPlayerRow({ onAdd, onCancel, canonicalPlayers }: { 
  onAdd: (name: string, gender: Gender, tier: Tier) => void; 
  onCancel: () => void;
  canonicalPlayers: Map<string, { gender: Gender; tier: Tier }>;
}) {
  const [name, setName] = useState('')
  const [gender, setGender] = useState<Gender>('M')
  const [tier, setTier] = useState<Tier>(2)

  // Auto-fill gender & tier when name matches a canonical player
  function handleNameChange(value: string) {
    setName(value)
    const normalized = value.trim().toLowerCase()
    const match = canonicalPlayers.get(normalized)
    if (match) {
      setGender(match.gender)
      setTier(match.tier)
    }
  }

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) return
    onAdd(trimmed, gender, tier)
  }

  return (
    <form onSubmit={submit} className="flex flex-wrap items-center gap-2 bg-slate-900 border border-indigo-600 rounded-xl px-3 py-2">
      <div className="w-7 h-7 rounded-full bg-slate-700 flex items-center justify-center text-slate-400 text-xs shrink-0">
        ?
      </div>
      <input
        autoFocus
        value={name}
        onChange={(e) => handleNameChange(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Escape') onCancel() }}
        placeholder={t('legacy.placeholder.playerName')}
        className="flex-1 bg-transparent text-white text-sm placeholder-slate-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
      />
      {/* Gender picker */}
      <GenderToggle value={gender} onChange={setGender} />
      {/* Tier picker */}
      <TierToggle value={tier} onChange={setTier} />
      <Button type="submit" variant="ghost" size="sm" disabled={!name.trim()}>
        {t('legacy.add')}
      </Button>
      <IconButton label={t('wizard.players.addCancel')} size="sm" onClick={onCancel}>
        ✕
      </IconButton>
    </form>
  )
}

// ── Bulk import ───────────────────────────────────────────────────────────────
function BulkImport({ onClose, existingCount, max, canonicalPlayers }: { 
  onClose: () => void; 
  existingCount: number; 
  max: number;
  canonicalPlayers: Map<string, { gender: Gender; tier: Tier }>;
}) {
  const addPlayers = useStore((s) => s.addPlayers)
  const [text, setText] = useState('')

  const parsed = parsePlayerList(text)
  const available = max - existingCount
  const preview = parsed.slice(0, available)
  const overflow = parsed.length - preview.length

  function handleImport() {
    if (preview.length === 0) return
    addPlayers(preview.map((name) => {
      const match = canonicalPlayers.get(name.toLowerCase())
      return { 
        name, 
        gender: match?.gender ?? 'M', 
        tier: match?.tier ?? 2 
      }
    }))
    onClose()
  }

  return (
    <div className="bg-elevated border border-border rounded-xl p-4 flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-white">Paste player list</span>
        <IconButton label={t('players.bulkClose')} size="sm" onClick={onClose}>
          ✕
        </IconButton>
      </div>
      <textarea
        autoFocus
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={"1. Rakha ✅\n2. Vina ✅\n3. Fakhri ✅"}
        rows={6}
        className="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-white placeholder-slate-500 text-sm font-sans focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent resize-none"
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
          <p className="text-xs text-slate-400 mt-1">Gender defaults to M, Tier to D+ — click to change after import.</p>
        </div>
      )}
      <div className="flex gap-2">
        <Button
          className="flex-1"
          disabled={preview.length === 0}
          onClick={handleImport}
        >
          Import {preview.length > 0 ? preview.length : ''} Players
        </Button>
        <Button variant="secondary" onClick={onClose}>
          {t('legacy.cancel')}
        </Button>
      </div>
    </div>
  )
}

// ── Page ──────────────────────────────────────────────────────────────────────
export default function PlayersPage() {
  const players = useStore((s) => s.players)
  const session = useStore((s) => s.session)
  const addPlayer = useStore((s) => s.addPlayer)
  const removePlayer = useStore((s) => s.removePlayer)
  const [showForm, setShowForm] = useState(false)
  const [showBulk, setShowBulk] = useState(false)
  const navigate = useNavigate()
  // Canonical players for auto-fill — via react-query (sama seperti AdminPlayersPage).
  const { data: canonicalRows } = useListPlayers()
  const { canonicalPlayers, canonicalList } = useMemo(() => {
    const map = new Map<string, { gender: Gender; tier: Tier }>()
    const list: Array<{ name: string; gender: Gender; tier: Tier }> = []
    for (const row of canonicalRows ?? []) {
      // Use tierInduk (canonical tier) if available, fallback to tier (display)
      const canonicalTier = row.tierInduk ? tierStringToNumber(row.tierInduk) : (row.tier || 2)
      const entry = { gender: row.gender as Gender, tier: canonicalTier as Tier }
      map.set(row.name.toLowerCase(), entry)
      list.push({ name: row.name, ...entry })
    }
    return { canonicalPlayers: map, canonicalList: list }
  }, [canonicalRows])

  const required = session.playerCount
  const isComplete = players.length === required

  function findAmbiguousMatches(name: string, isRegistered: boolean) {
    if (isRegistered) return []
    const norm = name.trim().toLowerCase()
    if (!norm || isPlaceholderName(norm)) return []
    return canonicalList.filter((c) => {
      const cNorm = c.name.toLowerCase()
      return cNorm.startsWith(norm + ' ') || cNorm.startsWith(norm + '(')
    })
  }

  const hasAmbiguous = players.some((p) => findAmbiguousMatches(p.name, canonicalPlayers.has(p.name.toLowerCase())).length > 0)

  function handleAdd(name: string, gender: Gender, tier: Tier) {
    addPlayer({ name, gender, tier })
    setShowForm(false)
  }

  const tierGroups = TIERS.map((t) => ({
    tier: t,
    players: players.filter((p) => p.tier === t),
  }))

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h1 className="text-lg font-bold text-fg mb-0.5">Players</h1>
          <p className="text-slate-400 text-sm">Click name to rename · Click badge to toggle gender/tier.</p>
        </div>
        <span className={`text-sm font-semibold px-3 py-1 rounded-full border ${
          isComplete
            ? 'text-emerald-400 border-emerald-700 bg-emerald-900/30'
            : players.length > required
            ? 'text-red-400 border-red-700 bg-red-900/30'
            : 'text-slate-300 border-slate-700 bg-slate-800'
        }`}>
          {players.length}/{required}
        </span>
      </div>

      {/* Bulk import panel */}
      {showBulk && (
        <BulkImport onClose={() => setShowBulk(false)} existingCount={players.length} max={required} canonicalPlayers={canonicalPlayers} />
      )}

      {/* Player list grouped by tier */}
      {players.length > 0 && (
        <div className="flex flex-col gap-4">
          {tierGroups.map(({ tier, players: group }) =>
            group.length === 0 ? null : (
              <div key={tier}>
                <div className="flex items-center gap-2 mb-2">
                  <TierBadge tier={tier} />
                  <span className="text-xs text-slate-400">{TIER_NAMES[tier]}</span>
                </div>
                <div className="flex flex-col gap-1.5">
                  {group.map((player) => {
                    const isReg = canonicalPlayers.has(player.name.toLowerCase())
                    const amb = findAmbiguousMatches(player.name, isReg)
                    return (
                      <PlayerRow 
                        key={player.id} 
                        player={player} 
                        onRemove={() => removePlayer(player.id)}
                        isRegistered={isReg}
                        ambiguousMatches={amb}
                      />
                    )
                  })}
                </div>
              </div>
            )
          )}
        </div>
      )}

      {/* Add row */}
      {showForm ? (
        <AddPlayerRow onAdd={handleAdd} onCancel={() => setShowForm(false)} canonicalPlayers={canonicalPlayers} />
      ) : (
        <div className="flex gap-2">
          <Button
            variant="dashed"
            className="flex-1"
            disabled={players.length >= required}
            onClick={() => setShowForm(true)}
          >
            + Add Player
          </Button>
          <Button
            variant="dashed"
            disabled={players.length >= required}
            onClick={() => handleAdd('tbd', 'M', 2)}
            title={t('players.tbdHint')}
          >
            + TBD
          </Button>
          <Button
            variant="dashed"
            disabled={players.length >= required}
            onClick={() => setShowBulk((v) => !v)}
            title={t('players.bulkHint')}
          >
            <Icon name="list" size={14} /> Bulk
          </Button>
        </div>
      )}

      {players.length === 0 && !showForm && !showBulk && (
        <EmptyState
          title={t('wizard.players.empty', { required })}
          icon={<Icon name="history" size={40} />}
        />
      )}

      {/* Progress hint */}
      {players.length > 0 && !isComplete && (
        <p className="text-xs text-center text-slate-400">
          {players.length < required
            ? `${required - players.length} more player${required - players.length > 1 ? 's' : ''} needed`
            : `${players.length - required} too many — remove ${players.length - required} to match session`}
        </p>
      )}

      <Button
        className="mt-2 w-full"
        disabled={!isComplete || !session.locked || hasAmbiguous}
        onClick={() => navigate('/session/constraints')}
      >
        {!session.locked
          ? 'Go to Setup to start session'
          : hasAmbiguous
          ? 'Select official player for ambiguous names ⚠️'
          : isComplete
          ? 'Next: Constraints →'
          : `Add players (${players.length}/${required})`}
      </Button>
    </div>
  )
}
