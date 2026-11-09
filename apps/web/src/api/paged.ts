// The one page envelope every collection route answers: `items`, `total` and
// `nextCursor`. `nextCursor` is the next offset when more rows remain and an
// empty string on the last page.

export type Page<T> = {
  items: T[]
  total: number
  nextCursor: string
}

/** The platform ceiling (`api.page_size_max`, seeded 500). */
export const API_PAGE_MAX = 500

/**
 * Reads every page of a collection. A screen that showed the whole list before
 * the server capped it keeps doing so, without pretending one page is the set:
 * the caller supplies the request so the legacy and v2 transports both work.
 */
export async function collectPages<T>(
  fetchPage: (offset: number, limit: number) => Promise<Page<T>>,
  pageSize: number = API_PAGE_MAX,
): Promise<T[]> {
  const items: T[] = []
  let offset = 0
  for (;;) {
    const page = await fetchPage(offset, pageSize)
    items.push(...(page.items ?? []))
    const next = Number(page.nextCursor)
    if (!page.nextCursor || !Number.isFinite(next) || next <= offset) return items
    offset = next
  }
}
