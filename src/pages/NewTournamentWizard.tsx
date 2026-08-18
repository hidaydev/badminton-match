import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useCreateTournament } from '../queries'
import { shuffle } from '../utils/array'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
  type TournamentSnapshot,
  type TournamentPair,
  type GroupId,
} from '../utils/tournament'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']
const PAIR_COUNT = 16
const emptyPair = () => ({ a: '', b: '' })

/**
 * Wizard tournament — format classic (16 pairs → 4 grup → create).
 * Format team menyusul (Fase 5).
 */
export default function NewTournamentWizard() {
  const { format = '' } = useParams()

  if (format === 'team') {
    return <TeamWizard />
  }
  return <ClassicWizard />
}

// ── Team wizard: identity → 36 pemain + kelas → 6 tim → create ─────────────

const TEAM_CLASSES = ['A+', 'A', 'B+', 'B', 'C+', 'C'] as const
type TeamClass = (typeof TEAM_CLASSES)[number]

const initialPlayers = () =>
  Array.from({ length: 36 }, (_, i) => ({ name: '', cls: TEAM_CLASSES[i % 6] }))

function TeamWizard() {
  const navigate = useNavigate()
  const { mutate: create, isPending } = useCreateTournament()

  const [step, setStep] = useState(1)
  const [name, setName] = useState('')
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10))
  const [players, setPlayers] = useState(initialPlayers)
  const [teamNames, setTeamNames] = useState(() => Array.from({ length: 6 }, (_, i) => `Tim ${i + 1}`)) // dipakai drawTeams
  const [teams, setTeams] = useState<{ id: string; name: string; players: { name: string; cls: TeamClass }[] }[]>([])

  // enforce: semua nama terisi & 6 per kelas
  const namesComplete = players.every((p) => p.name.trim() !== '')
  const classCount = TEAM_CLASSES.map((c) => players.filter((p) => p.cls === c).length)
  const classesBalanced = classCount.every((n) => n === 6)

  const updatePlayer = (i: number, patch: Partial<{ name: string; cls: TeamClass }>) => {
    setPlayers((prev) => prev.map((p, idx) => (idx === i ? { ...p, ...patch } : p)))
  }

  const drawTeams = () => {
    // 36 pemain diacak, lalu 1 per kelas masuk ke tiap tim (6 tim × 6 kelas)
    const shuffled = shuffle(players.map((p, i) => ({ ...p, idx: i })))
    const next = Array.from({ length: 6 }, (_, i) => ({
      id: `t${i + 1}`,
      name: teamNames[i].trim() || `Tim ${i + 1}`,
      players: [] as { name: string; cls: TeamClass }[],
    }))
    for (const cls of TEAM_CLASSES) {
      const withClass = shuffled.filter((p) => p.cls === cls)
      withClass.forEach((p, i) => {
        next[i % 6].players.push({ name: p.name.trim(), cls: p.cls })
      })
    }
    setTeams(next)
    // sinkronkan nama default ke state teamNames (biar rename konsisten)
    setTeamNames((prev) => next.map((_, i) => prev[i].trim() || `Tim ${i + 1}`))
  }

  const handleCreate = () => {
    if (!name.trim() || teams.length !== 6 || teams.some((t) => t.players.length !== 6)) return
    create(
      {
        format: 'team',
        name: name.trim(),
        date,
        teams: teams.map((t) => ({ id: t.id, name: t.name, players: t.players })),
        matches: [], // undian menyusul (hari-H)
      },
      {
        onSuccess: ({ id }) => navigate(`/tournaments/${id}`),
        onError: (err) => {
          console.error('create team tournament failed', err)
          alert('Gagal membuat tournament. Coba lagi.')
        },
      },
    )
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold text-fg">Team Tournament</h2>
        <span className="text-xs font-mono text-fg-dim">{step} · {['Setup', 'Players', 'Teams'][step - 1]}</span>
      </div>

      {step === 1 && (
        <div className="flex flex-col gap-3">
          <label className="flex flex-col gap-1">
            <span className="text-xs text-fg-dim">Tournament name</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="mis. Majadu Team Cup"
              className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
            />
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-xs text-fg-dim">Date</span>
            <input
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm font-mono text-fg focus:border-accent focus:outline-none scheme-dark"
            />
          </label>
          <button
            onClick={() => setStep(2)}
            disabled={!name.trim()}
            className="mt-2 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      )}

      {step === 2 && (
        <div className="flex flex-col gap-2.5">
          <p className="text-xs text-fg-dim">
            36 participants · kelas: {TEAM_CLASSES.map((c, i) => `${c}=${classCount[i]}`).join(' · ')}
            <span className={classesBalanced ? ' text-success' : ' text-warning'}>
              {classesBalanced ? ' ✓' : ' (must be 6 per class)'}
            </span>
          </p>
          <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
            {players.map((p, i) => (
              <div key={i} className="flex items-center gap-2 px-3 py-2">
                <span className="w-6 text-xs font-mono text-fg-dim shrink-0">{i + 1}</span>
                <input
                  value={p.name}
                  onChange={(e) => updatePlayer(i, { name: e.target.value })}
                  placeholder={`Participant ${i + 1}`}
                  className="flex-1 bg-elevated border border-border rounded-md px-2.5 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none min-w-0"
                />
                <select
                  value={p.cls}
                  onChange={(e) => updatePlayer(i, { cls: e.target.value as TeamClass })}
                  className="bg-elevated border border-border rounded-md px-2 py-2 text-xs font-mono text-fg focus:border-accent focus:outline-none shrink-0"
                >
                  {TEAM_CLASSES.map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
              </div>
            ))}
          </div>
          <button
            onClick={() => setStep(3)}
            disabled={!namesComplete || !classesBalanced}
            className="mt-1 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      )}

      {step === 3 && (
        <div className="flex flex-col gap-3">
          <div className="flex items-center justify-between">
            <p className="text-xs text-fg-dim">Team names (1 player per class)</p>
            <button
              onClick={drawTeams}
              className="text-xs px-3 py-1.5 rounded-md border border-border-subtle text-fg-dim hover:text-fg"
            >
              {teams.length === 6 ? 'Re-draw' : 'Form Teams'}
            </button>
          </div>
          {teams.length === 0 && (
            <p className="text-xs text-fg-dim">
              Click <span className="text-accent">Form Teams</span> to split the 36 participants into teams.
            </p>
          )}
          <div className="flex flex-col gap-2.5">
            {teams.map((t, i) => (
              <div key={t.id} className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
                <div className="flex items-center gap-2 px-3 py-1.5 border-b border-border-subtle">
                  <input
                    value={t.name}
                    onChange={(e) =>
                      setTeams((prev) => prev.map((x, xi) => (xi === i ? { ...x, name: e.target.value } : x)))
                    }
                    className="flex-1 bg-transparent text-sm font-semibold text-fg focus:outline-none"
                  />
                  <span className="text-[10px] font-mono text-fg-dim uppercase tracking-wider">
                    {t.players.length}/6
                  </span>
                </div>
                <div className="px-3 py-2 flex flex-wrap gap-x-3 gap-y-1">
                  {t.players.map((p) => (
                    <span key={p.cls} className="text-xs text-fg-dim font-mono">
                      <span className="text-accent">{p.cls}</span> {p.name}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
          <button
            onClick={handleCreate}
            disabled={teams.length !== 6 || teams.some((t) => t.players.length !== 6) || isPending}
            className="mt-1 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {isPending ? 'Creating…' : 'Create Tournament'}
          </button>
        </div>
      )}
    </div>
  )
}

function ClassicWizard() {
  const navigate = useNavigate()
  const { mutate: create, isPending } = useCreateTournament()

  const [step, setStep] = useState(1)
  const [name, setName] = useState('')
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10))
  const [pairs, setPairs] = useState(() => Array.from({ length: PAIR_COUNT }, emptyPair))
  const [groups, setGroups] = useState<Record<GroupId, string[]>>(() => ({ A: [], B: [], C: [], D: [] }))

  const pairsComplete = pairs.every((p) => p.a.trim() !== '' && p.b.trim() !== '')
  const groupsFull = GROUP_IDS.every((g) => groups[g].length === 4)

  const drawGroups = () => {
    const ids = shuffle(pairs.map((_, i) => `p${i + 1}`))
    const next: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }
    ids.forEach((id, idx) => {
      next[GROUP_IDS[Math.floor(idx / 4)]].push(id)
    })
    setGroups(next)
  }

  const updatePair = (i: number, key: 'a' | 'b', value: string) => {
    setPairs((prev) => prev.map((p, idx) => (idx === i ? { ...p, [key]: value } : p)))
  }

  const handleCreate = () => {
    if (!name.trim() || !pairsComplete || !groupsFull) return
    const pairsData: TournamentPair[] = pairs.map((p, i) => ({
      id: `p${i + 1}`,
      name: `${p.a.trim()} & ${p.b.trim()}`,
    }))
    const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, groups[g]))
    const allMatches = [...groupMatches, ...initKnockoutMatches()]
    const propagated = propagateBracket(allMatches, groups)
    const matches = assignGroupPics(pairsData, groups, propagated)
    const snapshot: TournamentSnapshot = {
      format: 'classic',
      name: name.trim(),
      date,
      pairs: pairsData,
      groups,
      matches,
    }
    create(snapshot, {
      onSuccess: ({ id }) => {
        navigate(`/tournaments/${id}`)
      },
      onError: (err) => {
        console.error('create tournament failed', err)
        alert('Gagal membuat tournament. Coba lagi.')
      },
    })
  }

  const groupNames = useMemo(() => {
    const nameOf = (id: string) => {
      const idx = Number(id.slice(1)) - 1
      return pairs[idx] ? `${pairs[idx].a.trim()} & ${pairs[idx].b.trim()}` : id
    }
    const out: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }
    for (const g of GROUP_IDS) out[g] = groups[g].map(nameOf)
    return out
  }, [groups, pairs])

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold text-fg">Classic Tournament</h2>
        <span className="text-xs font-mono text-fg-dim">{step} · {['Setup', 'Pairs', 'Draw'][step - 1]}</span>
      </div>

      {step === 1 && (
        <div className="flex flex-col gap-3">
          <label className="flex flex-col gap-1">
            <span className="text-xs text-fg-dim">Nama tournament</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="mis. Internal Cup 2026"
              className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
            />
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-xs text-fg-dim">Tanggal</span>
            <input
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm font-mono text-fg focus:border-accent focus:outline-none scheme-dark"
            />
          </label>
          <button
            onClick={() => setStep(2)}
            disabled={!name.trim()}
            className="mt-2 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      )}

      {step === 2 && (
        <div className="flex flex-col gap-2.5">
          <div className="flex items-center justify-between">
            <p className="text-xs text-fg-dim">
              Add <span className="text-accent">{PAIR_COUNT}</span> pairs
            </p>
            <button
              onClick={() => setPairs(Array.from({ length: PAIR_COUNT }, emptyPair))}
              className="text-xs text-fg-dim hover:text-fg"
            >
              Reset
            </button>
          </div>
          <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
            {pairs.map((p, i) => (
              <div key={i} className="flex items-center gap-2 px-3 py-2">
                <span className="w-6 text-xs font-mono text-fg-dim shrink-0">{i + 1}</span>
                <input
                  value={p.a}
                  onChange={(e) => updatePair(i, 'a', e.target.value)}
                  placeholder="Player 1"
                  className="flex-1 bg-elevated border border-border rounded-md px-2.5 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none min-w-0"
                />
                <span className="text-fg-dim text-xs shrink-0">&</span>
                <input
                  value={p.b}
                  onChange={(e) => updatePair(i, 'b', e.target.value)}
                  placeholder="Player 2"
                  className="flex-1 bg-elevated border border-border rounded-md px-2.5 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none min-w-0"
                />
              </div>
            ))}
          </div>
          <button
            onClick={() => setStep(3)}
            disabled={!pairsComplete}
            className="mt-1 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      )}

      {step === 3 && (
        <div className="flex flex-col gap-3">
          <div className="flex items-center justify-between">
            <p className="text-xs text-fg-dim">Draw: 4 groups × 4 pairs</p>
            <button
              onClick={drawGroups}
              className="text-xs px-3 py-1.5 rounded-md border border-border-subtle text-fg-dim hover:text-fg"
            >
              Re-draw
            </button>
          </div>
          {!groupsFull && (
            <p className="text-xs text-fg-dim">
              Click <span className="text-accent">Re-draw</span> to split the pairs into groups.
            </p>
          )}
          <div className="flex flex-col gap-2.5">
            {GROUP_IDS.map((g) => (
              <div key={g} className="bg-surface border border-border-subtle rounded-lg overflow-hidden">
                <div className="px-3 py-1.5 border-b border-border-subtle text-xs font-mono text-fg-dim uppercase tracking-wider">
                  Group {g}
                </div>
                {groupNames[g].map((n, i) => (
                  <div key={i} className="px-3 py-2 border-b border-border-subtle/50 last:border-0 text-sm text-fg truncate">
                    {n}
                  </div>
                ))}
              </div>
            ))}
          </div>
          <button
            onClick={handleCreate}
            disabled={!groupsFull || isPending}
            className="mt-1 w-full py-2.5 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {isPending ? 'Creating…' : 'Create Tournament'}
          </button>
        </div>
      )}
    </div>
  )
}
