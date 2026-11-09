/**
 * The app palette as data, for the surfaces that cannot read CSS custom
 * properties: the canvas export, the achievement medals and the scoreboard
 * footer. `index.css` declares the same values in `@theme`; this module is the
 * one TS file allowed to spell them out, so a brand colour changes in one place
 * per medium instead of four.
 */
export const PALETTE = {
  ground: '#0b0e13',
  surface: '#14181f',
  elevated: '#1c212b',
  border: '#2a313c',
  borderSubtle: '#22272f',
  fg: '#eef0f3',
  fgDim: '#8b939c',
  accent: '#e3b341',
  accentAlt: '#e3b341',
  success: '#43a57d',
  error: '#d65a5a',
  warning: '#e3b341',
  info: '#5b8fbd',
  /** Named intentional extension for team highlights, not part of the UI scale. */
  teamGreen: '#2ea865',
  teamGreenShimmer: '#6ddfa0',
  teamBlue: '#2e8fd4',
  teamBlueShimmer: '#7ec6f0',
  silver: '#c8cdd3',
  white: '#ffffff',
  black: '#000000',
  darkText: '#111111',
} as const
