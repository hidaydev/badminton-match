import { useEffect, useMemo, useRef, useState } from 'react'
import { Navigate, useNavigate, useParams } from 'react-router-dom'
import { t } from '../../i18n'
import { listPlayers } from '../../players/api'
import type { Player as ServerPlayer } from '../../players/api'
import { TIER_ACTIVE, TIER_BADGE_COLORS, TIER_LABELS, TIER_NAMES, TIERS, tierFromLabel } from '../tiers'
import { useWizard } from '../context'
import type { Gender, Player, Tier } from '../types'

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
        .trim(),
    )
    .filter((name) => name.length > 0)
}

function TierBadge({ tier }: { tier: Tier }) {
  return (
    <span className={`inline-flex items-center justify-center w-6 h-6 rounded-md border text-xs font-bold ${TIER_BADGE_COLORS[tier] ?? TIER_BADGE_COLORS[3]}`}>
      {TIER_LABELS[tier] ?? tier}
    </span>
  )
}

function GenderToggle({ value, onChange }: { value: Gender; onChange: (gender: Gender) => void }) {
  return (
    <div className="flex rounded-lg overflow-hidden border border-slate-700">
      {(['M', 'F'] as Gender[]).map((gender) => (
        <button
          key={gender}
          type="button"
          onClick={() => onChange(gender)}
          aria-pressed={value === gender}
          className={`px-2.5 py-1 text-xs font-semibold transition-colors ${
            value === gender
              ? gender === 'M'
                ? 'bg-blue-600 text-white'
                : 'bg-pink-600 text-white'
              : 'text-slate-400 hover:text-slate-200'
          }`}
        >
          {gender}
        </button>
      ))}
    </div>
  )
}

function TierToggle({ value, onChange }: { value: Tier; onChange: (tier: Tier) => void }) {
  return (
    <div className="flex rounded-lg overflow-hidden border border-slate-700">
      {TIERS.map((tier) => (
        <button
          key={tier}
          type="button"
          onClick={() => onChange(tier)}
          aria-pressed={value === tier}
          className={`min-w-8 h-8 text-xs font-bold transition-colors ${
            value === tier ? TIER_ACTIVE[tier] : 'text-slate-400 hover:text-slate-200'
          }`}
        >
          {TIER_LABELS[tier]}
        </button>
      ))}
    </div>
  )
}

type Canonical = Map<string, { gender: Gender; tier: Tier }>

function PlayerRow({
  player,
  onRemove,
  isRegistered,
  ambiguousMatches,
}: {
  player: Player
  onRemove: () => void
  isRegistered: boolean
  ambiguousMatches?: Array<{ name: string; gender: Gender; tier: Tier }>
}) {
  const { updatePlayer } = useWizard()
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
      <div className="flex items-center gap-1.5 sm:gap-2 bg-surface border border-border-subtle hover:border-slate-700 rounded-xl px-2.5 py-2 group transition-colors">
        <div className="w-7 h-7 rounded-full bg-slate-700 flex items-center justify-center text-xs font-bold text-slate-300 shrink-0">
          {player.name[0].toUpperCase()}
        </div>

        {editing ? (
          <input
            ref={inputRef}
            value={name}
            onChange={(event) => setName(event.target.value)}
            onBlur={save}
            onKeyDown={(event) => {
              if (event.key === 'Enter') save()
              if (event.key === 'Escape') {
                setName(player.name)
                setEditing(false)
              }
            }}
            aria-label={t('wizard.players.namePlaceholder')}
            className="flex-1 bg-slate-800 border border-accent rounded-lg px-2 py-1 text-white text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          />
        ) : (
          <button
            type="button"
            onClick={() => setEditing(true)}
            className="flex-1 text-left text-white font-medium text-sm cursor-text hover:text-accent transition-colors"
          >
            {player.name}
          </button>
        )}

        <GenderToggle value={player.gender} onChange={(gender) => updatePlayer(player.id, { gender })} />

        {isRegistered ? (
          <span className={`inline-flex items-center justify-center min-w-8 h-8 text-xs font-bold rounded-lg ${TIER_ACTIVE[player.tier]}`}>
            {TIER_LABELS[player.tier]}
          </span>
        ) : (
          <TierToggle value={player.tier} onChange={(tier) => updatePlayer(player.id, { tier })} />
        )}

        <button
          type="button"
          onClick={onRemove}
          className="text-slate-400 hover:text-red-400 active:text-red-400 text-sm transition-colors shrink-0 p-2"
          aria-label={t('wizard.players.remove')}
        >
          ✕
        </button>
      </div>

      {ambiguousMatches && ambiguousMatches.length > 0 && (
        <div className="bg-amber-950/70 border border-amber-600/70 rounded-xl p-2.5 flex flex-col gap-1.5 text-xs ml-1 mr-1">
          <span className="text-amber-300 font-semibold flex items-center gap-1">
            {t('wizard.players.ambiguousTitle', { name: player.name, count: ambiguousMatches.length })}
          </span>
          <div className="flex flex-wrap gap-1.5">
            {ambiguousMatches.map((match) => (
              <button
                key={match.name}
                type="button"
                onClick={() => {
                  updatePlayer(player.id, { name: match.name, gender: match.gender, tier: match.tier })
                  setName(match.name)
                }}
                className="bg-amber-900/90 hover:bg-amber-800 text-amber-100 border border-amber-500/60 font-medium px-2.5 py-1 rounded-lg transition-colors flex items-center gap-1.5 shadow-sm"
              >
                <span>{match.name}</span>
                <span className="text-[10px] opacity-80">
                  ({TIER_LABELS[match.tier]} · {match.gender})
                </span>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function AddPlayerRow({
  onAdd,
  onCancel,
  canonicalPlayers,
}: {
  onAdd: (name: string, gender: Gender, tier: Tier) => void
  onCancel: () => void
  canonicalPlayers: Canonical
}) {
  const [name, setName] = useState('')
  const [gender, setGender] = useState<Gender>('M')
  const [tier, setTier] = useState<Tier>(2)

  function handleNameChange(value: string) {
    setName(value)
    const match = canonicalPlayers.get(value.trim().toLowerCase())
    if (match) {
      setGender(match.gender)
      setTier(match.tier)
    }
  }

  function submit(event: React.FormEvent) {
    event.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) return
    onAdd(trimmed, gender, tier)
  }

  return (
    <form onSubmit={submit} className="flex items-center gap-2 bg-slate-900 border border-accent rounded-xl px-3 py-2">
      <div className="w-7 h-7 rounded-full bg-slate-700 flex items-center justify-center text-slate-400 text-xs shrink-0">?</div>
      <input
        autoFocus
        value={name}
        onChange={(event) => handleNameChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') onCancel()
        }}
        placeholder={t('wizard.players.namePlaceholder')}
        aria-label={t('wizard.players.namePlaceholder')}
        className="flex-1 bg-transparent text-white text-sm placeholder-slate-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
      />
      <GenderToggle value={gender} onChange={setGender} />
      <TierToggle value={tier} onChange={setTier} />
      <button
        type="submit"
        disabled={!name.trim()}
        className="text-accent hover:brightness-125 disabled:opacity-30 text-sm font-medium transition-colors"
      >
        {t('wizard.players.addAction')}
      </button>
      <button type="button" onClick={onCancel} className="text-slate-400 hover:text-slate-200 text-sm transition-colors" aria-label={t('wizard.players.addCancel')}>
        ✕
      </button>
    </form>
  )
}

function BulkImport({
  onClose,
  existingCount,
  max,
  canonicalPlayers,
}: {
  onClose: () => void
  existingCount: number
  max: number
  canonicalPlayers: Canonical
}) {
  const { addPlayers } = useWizard()
  const [text, setText] = useState('')

  const parsed = parsePlayerList(text)
  const available = max - existingCount
  const preview = parsed.slice(0, available)
  const overflow = parsed.length - preview.length

  function handleImport() {
    if (preview.length === 0) return
    addPlayers(
      preview.map((name) => {
        const match = canonicalPlayers.get(name.toLowerCase())
        return { name, gender: match?.gender ?? 'M', tier: match?.tier ?? 2 }
      }),
    )
    onClose()
  }

  return (
    <div className="bg-elevated border border-border rounded-xl p-4 flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-white">{t('wizard.players.bulkTitle')}</span>
        <button type="button" onClick={onClose} className="text-slate-400 hover:text-slate-200 text-sm" aria-label={t('wizard.players.cancel')}>
          ✕
        </button>
      </div>
      <textarea
        autoFocus
        value={text}
        onChange={(event) => setText(event.target.value)}
        placeholder={t('wizard.players.bulkPlaceholder')}
        aria-label={t('wizard.players.bulkTitle')}
        rows={6}
        className="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-white placeholder-slate-500 text-sm font-sans focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent resize-none"
      />
      {preview.length > 0 && (
        <div className="flex flex-col gap-1">
          <span className="text-xs text-slate-400">
            {preview.length === 1
              ? t('wizard.players.detectedOne')
              : t('wizard.players.detected', { count: preview.length })}
            {overflow > 0 ? ` ${t('wizard.players.skipped', { count: overflow })}` : ''}
          </span>
          <div className="flex flex-wrap gap-1">
            {preview.map((name) => (
              <span key={name} className="text-xs bg-slate-700 text-slate-200 px-2 py-0.5 rounded-full">
                {name}
              </span>
            ))}
          </div>
          <p className="text-xs text-slate-400 mt-1">{t('wizard.players.bulkHint')}</p>
        </div>
      )}
      <div className="flex gap-2">
        <button
          type="button"
          disabled={preview.length === 0}
          onClick={handleImport}
          className="flex-1 py-2.5 bg-accent hover:brightness-110 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 text-sm font-semibold rounded-lg transition-colors"
        >
          {t('wizard.players.import', { count: preview.length })}
        </button>
        <button type="button" onClick={onClose} className="px-4 py-2 text-slate-400 hover:text-slate-200 text-sm rounded-lg hover:bg-slate-700 transition-colors">
          {t('wizard.players.cancel')}
        </button>
      </div>
    </div>
  )
}

export default function PlayersPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const navigate = useNavigate()
  const { draft, addPlayer, removePlayer } = useWizard()
  const [showForm, setShowForm] = useState(false)
  const [showBulk, setShowBulk] = useState(false)
  const [canonicalRows, setCanonicalRows] = useState<ServerPlayer[]>([])

  useEffect(() => {
    let active = true
    listPlayers(slug, { limit: 1000 })
      .then((rows) => {
        if (active) setCanonicalRows(rows)
      })
      .catch(() => {
        if (active) setCanonicalRows([])
      })
    return () => {
      active = false
    }
  }, [slug])

  const { canonicalPlayers, canonicalList } = useMemo(() => {
    const map: Canonical = new Map()
    const list: Array<{ name: string; gender: Gender; tier: Tier }> = []
    for (const row of canonicalRows) {
      const entry = { gender: row.gender as Gender, tier: tierFromLabel(row.tier) }
      map.set(row.name.toLowerCase(), entry)
      list.push({ name: row.name, ...entry })
    }
    return { canonicalPlayers: map, canonicalList: list }
  }, [canonicalRows])

  if (!draft.session.locked) {
    return <Navigate to={`/c/${encodeURIComponent(slug)}/session/new`} replace />
  }

  const players = draft.players
  const required = draft.session.playerCount
  const isComplete = players.length === required

  function findAmbiguousMatches(name: string, isRegistered: boolean) {
    if (isRegistered) return []
    const normalized = name.trim().toLowerCase()
    if (!normalized) return []
    return canonicalList.filter((candidate) => {
      const candidateName = candidate.name.toLowerCase()
      return candidateName.startsWith(`${normalized} `) || candidateName.startsWith(`${normalized}(`)
    })
  }

  const hasAmbiguous = players.some(
    (player) => findAmbiguousMatches(player.name, canonicalPlayers.has(player.name.toLowerCase())).length > 0,
  )

  const tierGroups = TIERS.map((tier) => ({
    tier,
    players: players.filter((player) => player.tier === tier),
  }))

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="text-lg font-bold text-fg mb-0.5">{t('wizard.players.title')}</h2>
          <p className="text-slate-400 text-sm">{t('wizard.players.subtitle')}</p>
        </div>
        <span
          className={`text-sm font-semibold px-3 py-1 rounded-full border ${
            isComplete
              ? 'text-emerald-400 border-emerald-700 bg-emerald-900/30'
              : players.length > required
                ? 'text-red-400 border-red-700 bg-red-900/30'
                : 'text-slate-300 border-slate-700 bg-slate-800'
          }`}
        >
          {t('wizard.players.counter', { count: players.length, required })}
        </span>
      </div>

      {showBulk && (
        <BulkImport
          onClose={() => setShowBulk(false)}
          existingCount={players.length}
          max={required}
          canonicalPlayers={canonicalPlayers}
        />
      )}

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
                    const isRegistered = canonicalPlayers.has(player.name.toLowerCase())
                    return (
                      <PlayerRow
                        key={player.id}
                        player={player}
                        onRemove={() => removePlayer(player.id)}
                        isRegistered={isRegistered}
                        ambiguousMatches={findAmbiguousMatches(player.name, isRegistered)}
                      />
                    )
                  })}
                </div>
              </div>
            ),
          )}
        </div>
      )}

      {showForm ? (
        <AddPlayerRow
          onAdd={(name, gender, tier) => {
            addPlayer({ name, gender, tier })
            setShowForm(false)
          }}
          onCancel={() => setShowForm(false)}
          canonicalPlayers={canonicalPlayers}
        />
      ) : (
        <div className="flex gap-2">
          <button
            type="button"
            disabled={players.length >= required}
            onClick={() => setShowForm(true)}
            className="flex-1 py-2.5 border-2 border-dashed border-slate-700 hover:border-accent disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-accent rounded-xl text-sm font-medium transition-colors"
          >
            {t('wizard.players.add')}
          </button>
          <button
            type="button"
            disabled={players.length >= required}
            onClick={() => setShowBulk((value) => !value)}
            className="py-2.5 px-4 border-2 border-dashed border-slate-700 hover:border-emerald-500 disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-emerald-400 rounded-xl text-sm font-medium transition-colors"
            aria-label={t('wizard.players.bulk')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M8 6h13M8 12h13M8 18h13" />
              <path d="M3 6h.01M3 12h.01M3 18h.01" />
            </svg>
          </button>
        </div>
      )}

      {players.length === 0 && !showForm && !showBulk && (
        <div className="text-center py-12 text-slate-400">
          <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="mx-auto mb-3 text-slate-400">
            <circle cx="12" cy="8" r="4" />
            <path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" />
          </svg>
          <p>{t('wizard.players.empty', { required })}</p>
        </div>
      )}

      {players.length > 0 && !isComplete && (
        <p className="text-xs text-center text-slate-400">
          {players.length < required
            ? required - players.length === 1
              ? t('wizard.players.moreOne')
              : t('wizard.players.more', { count: required - players.length })
            : t('wizard.players.tooMany', { count: players.length - required })}
        </p>
      )}

      <button
        type="button"
        disabled={!isComplete || !draft.session.locked || hasAmbiguous}
        onClick={() => navigate(`/c/${encodeURIComponent(slug)}/session/constraints`)}
        className="w-full py-2.5 bg-accent hover:brightness-110 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors mt-2"
      >
        {!draft.session.locked
          ? t('wizard.players.locked')
          : hasAmbiguous
            ? t('wizard.players.ambiguous')
            : isComplete
              ? t('wizard.players.next')
              : t('wizard.players.needPlayers', { count: players.length, required })}
      </button>
    </div>
  )
}
