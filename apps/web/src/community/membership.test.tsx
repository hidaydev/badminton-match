import { describe, expect, it } from 'vitest'
import { renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { can } from './membership'
import { useMembership } from './membership'
import { CommunityContext } from './CommunityContext'
import type { CommunityContextValue } from './CommunityContext'
import type { Membership } from '../auth/api'

const MEMBERSHIPS: Membership[] = [
  {
    id: 'c1',
    slug: 'acme',
    name: 'Acme',
    role: 'admin',
  },
  {
    id: 'c2',
    slug: 'beta',
    name: 'Beta',
    role: 'host',
  },
  {
    id: 'c3',
    slug: 'gamma',
    name: 'Gamma',
    role: 'member',
  },
]

function wrapper(value: CommunityContextValue) {
  return ({ children }: { children: ReactNode }) => (
    <CommunityContext.Provider value={value}>{children}</CommunityContext.Provider>
  )
}

const context: CommunityContextValue = {
  memberships: MEMBERSHIPS,
  current: MEMBERSHIPS[0],
  select: () => undefined,
}

describe('can', () => {
  it('pins the role to capability table', () => {
    expect(can('admin', 'player.manage')).toBe(true)
    expect(can('admin', 'settings.edit')).toBe(true)
    expect(can('host', 'player.manage')).toBe(true)
    expect(can('host', 'settings.edit')).toBe(false)
    expect(can('member', 'player.manage')).toBe(false)
    expect(can('member', 'settings.edit')).toBe(false)
    expect(can(null, 'player.manage')).toBe(false)
  })
})

describe('useMembership', () => {
  it('returns the membership, the role and the capability check', () => {
    const { result } = renderHook(() => useMembership('beta'), { wrapper: wrapper(context) })

    expect(result.current.membership?.id).toBe('c2')
    expect(result.current.role).toBe('host')
    expect(result.current.can('player.manage')).toBe(true)
    expect(result.current.can('settings.edit')).toBe(false)
  })

  it('is null for a community the account does not belong to', () => {
    const { result } = renderHook(() => useMembership('nope'), { wrapper: wrapper(context) })

    expect(result.current.membership).toBeNull()
    expect(result.current.role).toBeNull()
    expect(result.current.can('player.manage')).toBe(false)
  })
})
