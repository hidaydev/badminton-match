// GlobalAmbiguousNames — sediakan himpunan baseName ambigu dari SELURUH
// populasi pemain, supaya badge "(i)" bekerja di semua layar.
//
// Kenapa perlu: provider per-halaman hanya dipasang di 3 tempat (GeneratePage,
// SharedSessionPage, RatingPlayerPage). Di halaman lain (papan ranking, daftar
// pemain, turnamen) context-nya default kosong -> badge (i) tidak pernah
// muncul. Akibatnya dua pemain ber-baseName sama tampil identik: di prod ada
// "Arya (Dika)" dan "Arya (Shania)" (rank 55 & 104 di papan) yang keduanya
// dirender sebagai "Arya" polos.
//
// Populasi penuh dipilih sebagai default karena itulah definisi ambiguitas yang
// paling tidak menyesatkan: sebuah nama ambigu kalau ada >1 pemain memakainya,
// bukan hanya >1 di antara yang kebetulan tampil. Halaman yang punya konteks
// lebih sempit tetap boleh menimpanya lewat AmbiguousNamesProvider (mis.
// GeneratePage hanya peduli nama yang ikut sesi itu).
import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { AmbiguousNamesProvider } from '../context/AmbiguousNamesContext'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { listPlayers } from '../queries/endpoints'

export default function GlobalAmbiguousNames({ children }: { children: React.ReactNode }) {
  const { data } = useQuery({
    queryKey: ['players', 'all'],
    queryFn: ({ signal }) => listPlayers(signal),
    staleTime: 5 * 60 * 1000,
  })

  const names = useMemo(
    () => collectAmbiguousBaseNames((data ?? []).map((p) => p.name)),
    [data],
  )

  return <AmbiguousNamesProvider value={names}>{children}</AmbiguousNamesProvider>
}
