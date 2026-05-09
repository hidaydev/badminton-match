import { useState } from 'react'
import { useTournamentStore } from '../store/tournament'
import GroupAssignment from '../components/tournament/GroupAssignment'
import GroupMatches from '../components/tournament/GroupMatches'
import BracketTab from '../components/tournament/BracketTab'

type Tab = 'groups' | 'bracket'

export default function TournamentPage() {
  const [tab, setTab] = useState<Tab>('groups')
  const name = useTournamentStore((s) => s.name)
  const date = useTournamentStore((s) => s.date)
  const groupsLocked = useTournamentStore((s) => s.groupsLocked)

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: 'Groups' },
    { id: 'bracket', label: 'Bracket' },
  ]

  return (
    <div className="flex flex-col gap-0 -mx-3">
      {/* Header */}
      <div className="bg-slate-800 px-4 pt-4 pb-0 border-b border-slate-700">
        <h2 className="text-base font-bold text-white leading-tight">{name}</h2>
        <p className="text-xs text-slate-500 mt-0.5 mb-3">
          {new Date(date).toLocaleDateString('id-ID', {
            day: 'numeric',
            month: 'long',
            year: 'numeric',
          })}{' '}
          · 16 pairs · 4 groups
        </p>
        <div className="flex">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex-1 py-2.5 text-sm font-semibold border-b-2 transition-colors ${
                tab === t.id
                  ? 'text-yellow-400 border-yellow-400'
                  : 'text-slate-500 border-transparent hover:text-slate-300'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* Tab content */}
      <div className="px-3 pt-4 pb-8">
        {tab === 'groups' && (groupsLocked ? <GroupMatches /> : <GroupAssignment />)}
        {tab === 'bracket' && <BracketTab />}
      </div>
    </div>
  )
}
