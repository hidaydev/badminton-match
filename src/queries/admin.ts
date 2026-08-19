// src/queries/admin.ts — request admin (Bearer otomatis via setAdminToken).
import { request } from './endpoints'

/** adminRequest — panggil endpoint admin (token di-attach otomatis). */
export async function adminRequest<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  return await request<T>(method, path, body)
}
