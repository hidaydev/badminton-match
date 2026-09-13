// src/config/achievements.ts, palet visual achievement.
//
// Alasan (R-31):
// - MEDAL_TONES: tangga pangkat Bronze..Onyx. Satu hue-family metalik per
//   tingkat supaya tingkat langsung kebaca, tanpa mengubah palet inti app.
// - EVENT_TONES: medal event (turnamen/season) sengaja lebih variatif supaya
//   tiap event terasa unik, meniru medal event Ingress. Ini pengecualian palet
//   yang disengaja: warnanya redup dan tetap cocok di dark UI; indigo/violet
//   tetap dihindari sesuai aturan redesign app.

// Bronze, Silver, Gold, Platinum, Onyx.
export const MEDAL_TONES = ['#c08552', '#c7ccd1', '#e3b341', '#a5d8e0', '#9aa4b2']

// Nama tingkat 1..5, dipakai untuk tangga di popup detail.
export const MEDAL_TIER_NAMES = ['Bronze', 'Silver', 'Gold', 'Platinum', 'Onyx']

export const EVENT_TONES = [
  '#e3b341', // gold
  '#d08a4f', // copper
  '#b9a24e', // olive
  '#8fae7a', // moss
  '#6fa8a0', // teal
  '#6d8fc4', // steel blue
  '#c47b7b', // muted red
  '#a89b7a', // khaki
]
