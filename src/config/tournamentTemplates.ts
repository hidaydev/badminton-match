// src/config/tournamentTemplates.ts
// Template assets untuk team tournament standings post.

export interface TournamentTemplate {
  id: string
  label: string
  width: number
  height: number
  logo?: string
  sponsor?: string
  badge?: string
  background?: string
}

export const tournamentTemplate: TournamentTemplate = {
  id: 'team-standings-v1',
  label: 'Team Tournament Standings',
  width: 1080,
  height: 1350,
  logo: '/instagram-logo.png',
  sponsor: '/sponsor-logo.png',
  badge: '/tournament-badge.png',
  background: '/summary-bg.png',
}
