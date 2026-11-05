import { describe, expect, it } from 'vitest'
import { communitySlugFromPath } from './routes.manifest'

describe('communitySlugFromPath', () => {
  it('reads the community slug from a community path', () => {
    expect(communitySlugFromPath('/c/acme')).toBe('acme')
    expect(communitySlugFromPath('/c/acme/sessions')).toBe('acme')
    expect(communitySlugFromPath('/c/acme/players/p1')).toBe('acme')
  })

  it('decodes an encoded slug', () => {
    expect(communitySlugFromPath('/c/my%20club')).toBe('my club')
  })

  it('returns null outside a community path', () => {
    expect(communitySlugFromPath('/')).toBeNull()
    expect(communitySlugFromPath('/s/code')).toBeNull()
    expect(communitySlugFromPath('/owner/communities')).toBeNull()
  })
})
