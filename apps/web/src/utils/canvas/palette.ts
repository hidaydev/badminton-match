// Colours and fonts for the social exports.
//
// The six core values are the v1 `CANVAS_COLORS` palette carried over verbatim;
// the rest are the accents v1 used for ranks, scores and surfaces. These are
// presentation constants, not business numbers: the canvas size always comes
// from the community config (see `dimensions.ts`).

/** Primary accent (yellow). */
export const ACCENT = '#facc15'
/** Brand yellow, slightly warmer than the accent. */
export const BRAND = '#F5B400'
/** Dark background behind the standings card. */
export const BG_DARK = '#1e293b'
/** Muted text and secondary labels. */
export const MUTED = '#64748b'
/** Borders, dividers and column headings. */
export const BORDER = '#475569'
/** Primary text on a dark surface. */
export const TEXT = '#e2e8f0'

export const CANVAS_COLORS = {
  accent: ACCENT,
  brand: BRAND,
  bgDark: BG_DARK,
  muted: MUTED,
  border: BORDER,
  text: TEXT,
  /** Dimmed text (v1 `textDim`). */
  textDim: '#94a3b8',
  success: '#4ade80',
  error: '#f87171',
  /** Bronze / third place. */
  warning: '#fb923c',
  /** Silver / second place. */
  silver: '#cbd5e1',
  white: '#ffffff',
  black: '#000000',
  /** Text sitting on the yellow brand plate. */
  darkText: '#111111',
} as const

/** Standings card surface (v1 `rgba(5, 18, 42, 0.97)`). */
export const CARD_FILL = 'rgba(5, 18, 42, 0.97)'
/** Classic cover surface when no background image is supplied. */
export const CLASSIC_SURFACE = '#0f172a'
/** Group summary surface when no background image is supplied. */
export const GROUP_SURFACE = '#f59e0b'
/** Team match base and partai band. */
export const TEAM_BASE = '#03070f'
export const TEAM_PANEL = 'rgba(3,7,15,0.97)'

/** Row highlight for the top three (and for advancing pairs). */
export const ROW_HIGHLIGHT = 'rgba(250, 204, 21, 0.14)'
export const ROW_BASE = 'rgba(255, 255, 255, 0.04)'
export const ROW_ADVANCING = 'rgba(250,204,21,0.07)'
export const HEADER_ROW_FILL = 'rgba(255,255,255,0.04)'
export const DIVIDER = 'rgba(250,204,21,0.25)'

/** Decorative families declared in `index.html`. */
export const FONT_SANS = '"IBM Plex Sans", Arial, sans-serif'
export const FONT_MONO = '"IBM Plex Mono", monospace'
/** Replaces v1 Granesta; drawn with a -9 degree skew. */
export const FONT_ROAD_RAGE = '"Road Rage", Impact, sans-serif'
export const FONT_EDOSZ = '"Edosz", Impact, sans-serif'

/** Road Rage keeps the v1 Granesta posture at -9 degrees. */
export const ROAD_RAGE_SKEW_DEG = -9
/** Month label leans the other way, as it did in v1. */
export const MONTH_ROTATION_DEG = -5
/** Year plate brush stroke angle. */
export const YEAR_PLATE_ROTATION_DEG = -6
