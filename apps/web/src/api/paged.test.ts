import { describe, expect, it, vi } from 'vitest'
import { collectPages } from './paged'
import type { Page } from './paged'

type Row = { id: string }

function page(items: Row[], total: number, nextCursor: string): Page<Row> {
  return { items, total, nextCursor }
}

describe('collectPages', () => {
  it('returns one page when the server reports no next cursor', async () => {
    const fetchPage = vi.fn(async () => page([{ id: 'a' }], 1, ''))
    await expect(collectPages<Row>(fetchPage)).resolves.toEqual([{ id: 'a' }])
    expect(fetchPage).toHaveBeenCalledTimes(1)
    expect(fetchPage).toHaveBeenCalledWith(0, 500)
  })

  it('follows nextCursor until the last page', async () => {
    const pages = new Map<number, Page<Row>>([
      [0, page([{ id: 'a' }, { id: 'b' }], 3, '2')],
      [2, page([{ id: 'c' }], 3, '')],
    ])
    const fetchPage = vi.fn(async (offset: number) => pages.get(offset)!)
    await expect(collectPages<Row>(fetchPage, 2)).resolves.toEqual([
      { id: 'a' },
      { id: 'b' },
      { id: 'c' },
    ])
    expect(fetchPage.mock.calls).toEqual([
      [0, 2],
      [2, 2],
    ])
  })

  it('stops on a cursor that does not move forward', async () => {
    const fetchPage = vi.fn(async () => page([{ id: 'a' }], 99, '0'))
    await expect(collectPages<Row>(fetchPage)).resolves.toEqual([{ id: 'a' }])
    expect(fetchPage).toHaveBeenCalledTimes(1)
  })

  it('treats a malformed cursor as the last page', async () => {
    const fetchPage = vi.fn(async () => page([{ id: 'a' }], 99, 'not-a-number'))
    await expect(collectPages<Row>(fetchPage)).resolves.toEqual([{ id: 'a' }])
  })
})
