import type { CloudSnapshot, SessionMeta } from '../../queries/types'

export interface SessionRepository {
  getSession(id: string): Promise<CloudSnapshot | null>
  publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot>
  listSessions(): Promise<SessionMeta[]>
  deleteSession(lookup: string): Promise<{ deleted: boolean; sessionId: string }>
  unlockSession(id: string): Promise<CloudSnapshot>
}
