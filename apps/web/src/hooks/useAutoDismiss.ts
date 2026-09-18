import { useEffect } from 'react'
import { getSaveErrorMessage } from '../queries/errors'

/**
 * Auto-clear `value` setelah `ms` milidetik. Pola yang sebelumnya diulang di
 * TournamentPage/TeamTournamentPage/GeneratePage/SharedSessionPage.
 * Timer dibersihkan saat value berubah atau komponen unmount.
 */
export function useAutoDismiss<T>(value: T | null, setValue: (value: T | null) => void, ms: number) {
  useEffect(() => {
    if (!value) return
    const timer = setTimeout(() => setValue(null), ms)
    return () => clearTimeout(timer)
  }, [value, ms, setValue])
}

/**
 * Handler standar mutation: bersihkan toast saat sukses, tampilkan pesan dari
 * error saat gagal. Dipakai SharedSessionPage & TournamentPage untuk menghindari
 * pasangan onSuccess/onError yang berulang.
 */
export function mutationToastHandlers(setSaveError: (message: string | null) => void) {
  return {
    onSuccess: () => setSaveError(null),
    onError: (error: unknown) => setSaveError(getSaveErrorMessage(error)),
  }
}
