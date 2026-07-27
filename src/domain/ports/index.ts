// TODO: These interfaces are prepared for future dependency injection.
// Currently unused — the app still uses queries/endpoints.ts directly.
// To wire in: create a DI container and inject repositories into hooks/pages.

export type { SessionRepository } from './SessionRepository'
export type { TournamentRepository } from './TournamentRepository'
export type { PlayerRepository } from './PlayerRepository'
