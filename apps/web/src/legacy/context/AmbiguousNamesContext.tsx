// AmbiguousNamesContext: the set of baseNames that are ambiguous (appear more
// than once) in the player list currently on screen. AnnotatedPlayerName reads
// it to decide whether the "(i)" badge has to be shown.
//
// GlobalAmbiguousNames supplies the global default (the whole player
// population), so the badge works on every screen. A page with a narrower
// context may override it through AmbiguousNamesProvider.
/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext } from 'react'

// combineAmbiguous lives in utils/nameParser (no JSX) so a node --test runner
// without --jsx can exercise it.
export { combineAmbiguous } from '../utils/nameParser'

const AmbiguousNamesContext = createContext<ReadonlySet<string>>(new Set())

export const AmbiguousNamesProvider = AmbiguousNamesContext.Provider

export function useAmbiguousNames(): ReadonlySet<string> {
  return useContext(AmbiguousNamesContext)
}

