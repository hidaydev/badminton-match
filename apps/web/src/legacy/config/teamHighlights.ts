import { PALETTE } from '../../theme/palette'

export const TEAM_HIGHLIGHT_ENABLED = true

export const TEAM_HIGHLIGHTS: Record<string, { logo: string; logoSize: number; color: string; shimmer: string }> = {
  'Green Grove': {
    logo: '/team-logos/Green_Grove-removebg-preview.png',
    logoSize: 16,
    color: PALETTE.teamGreen,
    shimmer: PALETTE.teamGreenShimmer,
  },
  'Blue Waves': {
    logo: '/team-logos/Blue_Waves-removebg-preview.png',
    logoSize: 14,
    color: PALETTE.teamBlue,
    shimmer: PALETTE.teamBlueShimmer,
  },
}

export const HIGHLIGHTED_PLAYERS: Record<string, keyof typeof TEAM_HIGHLIGHTS> = {
  Ginanjar: 'Green Grove',
  Dayat: 'Green Grove',
  Faiz: 'Green Grove',
  Maul: 'Green Grove',
  Dwi: 'Green Grove',
  Nindya: 'Green Grove',
  Fahmi: 'Blue Waves',
  Tari: 'Blue Waves',
  Rizky: 'Blue Waves',
  Ismet: 'Blue Waves',
  Andri: 'Blue Waves',
  Fachri: 'Blue Waves',
}
