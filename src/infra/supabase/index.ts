// TODO: These interfaces are prepared for future dependency injection.
// Currently unused — the app still uses queries/endpoints.ts directly.
// To wire in: create a DI container and inject repositories into hooks/pages.

export { SupabaseSessionRepository } from './SupabaseSessionRepository'
export { SupabaseTournamentRepository } from './SupabaseTournamentRepository'
export { SupabasePlayerRepository } from './SupabasePlayerRepository'
