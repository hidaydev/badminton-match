import { describe, expect, it } from 'vitest'
import { communityHref, communitySlugFromPath } from './routes.manifest'

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

describe('communityHref', () => {
  it('prefixes a slug-less legacy path', () => {
    expect(communityHref('acme', '/sessions')).toBe('/c/acme/sessions')
    expect(communityHref('acme', '/')).toBe('/c/acme')
    expect(communityHref('acme', '/s/abc')).toBe('/c/acme/s/abc')
  })

  it('leaves absolute paths alone', () => {
    expect(communityHref('acme', '/c/other/sessions')).toBe('/c/other/sessions')
    expect(communityHref('acme', '/owner/communities')).toBe('/owner/communities')
  })

  it('does not prefix when no community is active', () => {
    expect(communityHref('', '/sessions')).toBe('/sessions')
  })

  it('encodes the slug', () => {
    expect(communityHref('my club', '/players')).toBe('/c/my%20club/players')
  })
})
