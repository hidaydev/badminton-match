// src/config/tournament.ts
// Konfigurasi tournament — dipisah dari logika murni (utils/tournament.ts).

import type { GroupId } from '../utils/tournament'

/** Nomor court yang dipakai tiap grup saat round-robin (konfigurasi venue). */
export const GROUP_COURTS: Record<GroupId, number> = { A: 9, B: 10, C: 11, D: 12 }
