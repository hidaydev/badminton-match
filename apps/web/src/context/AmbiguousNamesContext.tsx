// AmbiguousNamesContext — himpunan baseName yang ambigu (muncul >1x) dalam
// daftar pemain yang sedang ditampilkan. Dipakai AnnotatedPlayerName untuk
// memutuskan apakah badge "(i)" perlu tampil.
//
// Default global disediakan GlobalAmbiguousNames (dari seluruh populasi
// pemain) sehingga badge bekerja di semua layar. Halaman yang punya konteks
// lebih sempit boleh menimpa lewat AmbiguousNamesProvider.
import { createContext, useContext } from 'react'

// combineAmbiguous tinggal di utils/nameParser (tanpa JSX) supaya bisa diuji
// runner node --test yang tidak menyetel --jsx.
export { combineAmbiguous } from '../utils/nameParser'

const AmbiguousNamesContext = createContext<ReadonlySet<string>>(new Set())

export const AmbiguousNamesProvider = AmbiguousNamesContext.Provider

export function useAmbiguousNames(): ReadonlySet<string> {
  return useContext(AmbiguousNamesContext)
}

