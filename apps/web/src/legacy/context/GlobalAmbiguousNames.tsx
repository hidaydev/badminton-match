// GlobalAmbiguousNames: supplies the ambiguous baseName set for the WHOLE
// player population, so the "(i)" badge works on every screen.
//
// Why it is needed: the per-page provider was only mounted in 3 places
// (GeneratePage, SharedSessionPage, RatingPlayerPage). On the other pages (the
// rankings board, the player list, tournaments) the context defaulted to empty,
// so the (i) badge never appeared. Two players sharing a baseName then rendered
// identically: production had "Arya (Dika)" and "Arya (Shania)" (rank 55 and
// 104 on the board) both rendered as a plain "Arya".
//
// The full population is the default because it is the least misleading
// definition of ambiguity: a name is ambiguous when more than one player uses
// it, not only when two of them happen to share a screen. A page with a
// narrower context may still override it through AmbiguousNamesProvider (for
// example GeneratePage only cares about the names in that session).
import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { AmbiguousNamesProvider } from '../context/AmbiguousNamesContext'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { listPlayers } from '../queries/endpoints'
import { communityQueryKey } from '../queries/keys'

export default function GlobalAmbiguousNames({ children }: { children: React.ReactNode }) {
  const { data } = useQuery({
    queryKey: communityQueryKey('players', 'all'),
    queryFn: ({ signal }) => listPlayers(signal),
    staleTime: 5 * 60 * 1000,
  })

  const names = useMemo(
    () => collectAmbiguousBaseNames((data ?? []).map((p) => p.name)),
    [data],
  )

  return <AmbiguousNamesProvider value={names}>{children}</AmbiguousNamesProvider>
}
