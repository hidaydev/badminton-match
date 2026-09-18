// AmbiguousNamesContext — himpunan baseName yang ambigu (muncul >1x) dalam
// daftar pemain yang sedang ditampilkan. Dipakai AnnotatedPlayerName untuk
// memutuskan apakah badge "(i)" perlu tampil.
//
// Tanpa provider → himpunan kosong → tidak ada badge (benar untuk konteks
// yang hanya menampilkan satu nama, mis. halaman rating pemain).
import { createContext, useContext } from 'react'

const AmbiguousNamesContext = createContext<ReadonlySet<string>>(new Set())

export const AmbiguousNamesProvider = AmbiguousNamesContext.Provider

export function useAmbiguousNames(): ReadonlySet<string> {
  return useContext(AmbiguousNamesContext)
}
