import type { SessionRepository } from '../../domain/ports/SessionRepository'
import type { CloudSnapshot, SessionMeta } from '../../queries/types'
import {
  getSession,
  publishSession,
  listSessions,
  deleteSession,
  unlockSession,
} from '../../queries/endpoints'

export class SupabaseSessionRepository implements SessionRepository {
  async getSession(id: string): Promise<CloudSnapshot | null> {
    return getSession(id)
  }

  async publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot> {
    return publishSession(id, data)
  }

  async listSessions(): Promise<SessionMeta[]> {
    return listSessions()
  }

  async deleteSession(lookup: string): Promise<{ deleted: boolean; sessionId: string }> {
    return deleteSession(lookup)
  }

  async unlockSession(id: string): Promise<CloudSnapshot> {
    return unlockSession(id)
  }
}
