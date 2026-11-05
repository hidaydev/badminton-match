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

export interface MedalTierStyle {
  level: number
  name: string
  tone: string
  rimStops: [string, string, string, string, string]
  faceStops: [string, string]
  glyphStops: [string, string, string]
  specular: string
  glow: string
  pillBg: string
  pillText: string
  pillBorder: string
}

export const MEDAL_TIER_STYLES: MedalTierStyle[] = [
  {
    level: 1,
    name: 'Bronze',
    tone: '#c08552',
    rimStops: ['#f8cda4', '#e0985c', '#b36d33', '#713b16', '#a45d27'],
    faceStops: ['#2e1b12', '#120a06'],
    glyphStops: ['#ffe2c7', '#df8c49', '#8a4213'],
    specular: '#ffe4cc',
    glow: 'rgba(192, 133, 82, 0.45)',
    pillBg: 'bg-amber-950/40',
    pillText: 'text-[#e0985c]',
    pillBorder: 'border-[#b36d33]/50',
  },
  {
    level: 2,
    name: 'Silver',
    tone: '#c7ccd1',
    rimStops: ['#ffffff', '#e3e7ec', '#b2bac4', '#667180', '#9aa4b0'],
    faceStops: ['#22272e', '#0d1013'],
    glyphStops: ['#ffffff', '#cfd6de', '#717d8c'],
    specular: '#ffffff',
    glow: 'rgba(199, 204, 209, 0.45)',
    pillBg: 'bg-slate-800/60',
    pillText: 'text-[#e3e7ec]',
    pillBorder: 'border-[#b2bac4]/50',
  },
  {
    level: 3,
    name: 'Gold',
    tone: '#e3b341',
    rimStops: ['#fff4c4', '#f8d254', '#d89b1c', '#7d5206', '#be8512'],
    faceStops: ['#2c210d', '#110c04'],
    glyphStops: ['#fff8d9', '#f3c144', '#946108'],
    specular: '#fffbe8',
    glow: 'rgba(227, 179, 65, 0.5)',
    pillBg: 'bg-yellow-950/40',
    pillText: 'text-[#f8d254]',
    pillBorder: 'border-[#d89b1c]/50',
  },
  {
    level: 4,
    name: 'Platinum',
    tone: '#a5d8e0',
    rimStops: ['#ffffff', '#c5f2f8', '#73c9d8', '#256d7d', '#55b4c4'],
    faceStops: ['#10242b', '#050f13'],
    glyphStops: ['#f0fdff', '#85dceb', '#2c7c8c'],
    specular: '#e8fbff',
    glow: 'rgba(165, 216, 224, 0.5)',
    pillBg: 'bg-cyan-950/40',
    pillText: 'text-[#73c9d8]',
    pillBorder: 'border-[#42a8b9]/50',
  },
  {
    level: 5,
    name: 'Onyx',
    tone: '#9aa4b2',
    rimStops: ['#e6edf5', '#9ab0c7', '#506378', '#1c2633', '#3e4f63'],
    faceStops: ['#1b212b', '#080b0f'],
    glyphStops: ['#f1f5f9', '#94a3b8', '#475569'],
    specular: '#f8fafc',
    glow: 'rgba(154, 164, 178, 0.45)',
    pillBg: 'bg-slate-900/80',
    pillText: 'text-[#cbd5e1]',
    pillBorder: 'border-[#64748b]/50',
  },
]

function parseHex(hex: string): [number, number, number] {
  const c = hex.replace('#', '')
  const n = parseInt(c.length === 3 ? c.split('').map((x) => x + x).join('') : c, 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

function blendRgb(
  [r, g, b]: [number, number, number],
  [tr, tg, tb]: [number, number, number],
  ratio: number,
): string {
  const nr = Math.round(r + (tr - r) * ratio)
  const ng = Math.round(g + (tg - g) * ratio)
  const nb = Math.round(b + (tb - b) * ratio)
  return `rgb(${nr}, ${ng}, ${nb})`
}

export function getEventMedalStyle(toneHex: string): MedalTierStyle {
  const rgb = parseHex(toneHex)
  const white: [number, number, number] = [255, 255, 255]
  const black: [number, number, number] = [0, 0, 0]

  return {
    level: 0,
    name: 'Event Medal',
    tone: toneHex,
    rimStops: [
      blendRgb(rgb, white, 0.55),
      blendRgb(rgb, white, 0.25),
      toneHex,
      blendRgb(rgb, black, 0.55),
      blendRgb(rgb, black, 0.22),
    ],
    faceStops: [blendRgb(rgb, black, 0.82), blendRgb(rgb, black, 0.94)],
    glyphStops: [
      blendRgb(rgb, white, 0.65),
      blendRgb(rgb, white, 0.15),
      blendRgb(rgb, black, 0.45),
    ],
    specular: blendRgb(rgb, white, 0.8),
    glow: `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, 0.45)`,
    pillBg: 'bg-slate-800/50',
    pillText: 'text-fg',
    pillBorder: 'border-border',
  }
}

