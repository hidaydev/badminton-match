import { request } from '../auth/api'

export type CreatedCommunity = {
  id: string
  slug: string
  name: string
  timezone: string
}

export type NewCommunity = {
  slug: string
  name: string
  adminEmail: string
  timezone?: string
}

/**
 * Platform owner only. The first admin gets an invite bound to `adminEmail`, so
 * membership starts at that address's next login rather than here.
 */
export function createCommunity(input: NewCommunity): Promise<CreatedCommunity> {
  return request<CreatedCommunity>('/communities', {
    method: 'POST',
    body: JSON.stringify(input),
  })
}
