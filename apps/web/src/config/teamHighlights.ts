export const TEAM_HIGHLIGHT_ENABLED = true

export const TEAM_HIGHLIGHTS: Record<string, { logo: string; logoSize: number; color: string; shimmer: string }> = {
  'Green Grove': {
    logo: '/team-logos/Green_Grove-removebg-preview.png',
    logoSize: 16,
    color: '#2ea865',
    shimmer: '#6ddfa0',
  },
  'Blue Waves': {
    logo: '/team-logos/Blue_Waves-removebg-preview.png',
    logoSize: 14,
    color: '#2e8fd4',
    shimmer: '#7ec6f0',
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
