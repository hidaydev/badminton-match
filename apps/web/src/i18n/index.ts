// src/i18n/index.ts — skeleton i18n ringan (zero deps).
// `t(key)` resolve path bertitik ke string dictionary; fungsi template dinamis
// (confirm/prompt) dipanggil langsung dari `en` (lihat pemakaian di AdminPage).
// Hanya `en` aktif — tanpa language switcher.

import { en } from './en'

type Messages = typeof en

/** Deep dot-key yang leaf-nya string (fungsi template dikecualikan). */
export type MessageKey = {
  [K in keyof Messages]: Messages[K] extends Record<string, unknown>
    ? {
        [SubK in keyof Messages[K]]: Messages[K][SubK] extends string
          ? `${K & string}.${SubK & string}`
          : never
      }[keyof Messages[K]]
    : never
}[keyof Messages]

/** Resolve 'admin.title' → 'Admin'. Fallback: kembalikan key (defensive). */
export function t(key: MessageKey): string {
  const value = key.split('.').reduce<unknown>((o, k) => (o as Record<string, unknown>)?.[k], en)
  return typeof value === 'string' ? value : key
}

/** Hook React — `t` statis, tidak memicu re-render. */
export function useT() {
  return { t }
}

export { en }
