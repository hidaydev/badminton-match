import { skipToken, useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { settled } from '../api/settled'
import { ApiError } from '../auth/api'
import { getPlayer, getMyPlayer, listClaims, listPlayers, PLAYER_PAGE } from './api'
import type { Player, PlayerClaim } from './api'

export type PlayersError = 'notFound' | 'failed'

function settleError(error: unknown): PlayersError {
  return error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
}

/**
 * The keys the player reads live under. Two screens asking for the same list
 * share one cache entry, which is what stops the detail page from re-reading a
 * list the roster already has; a write that changes a player invalidates them.
 * A missing slug or id is part of the key, so an idle read is never mixed with
 * a community that does exist.
 */
export const playerKeys = {
  list: (slug: string | null, query: string) => ['players', slug, 'list', query] as const,
  mine: (slug: string | null) => ['players', slug, 'mine'] as const,
  detail: (slug: string | null, id: string | null) => ['players', slug, 'detail', id] as const,
  claims: (slug: string | null, id: string | null) => ['players', slug, 'claims', id] as const,
}

/**
 * The player this account owns, for the home shortcut. A failed read hides the
 * card instead of blocking the page: the shortcut is a convenience.
 */
export function useMyPlayer(slug: string | null): Player | null {
  const { data } = useQuery({
    queryKey: playerKeys.mine(slug),
    // `skipToken` keeps the key and the function in one place: the read is idle
    // until there is a community, and the types narrow without a cast.
    queryFn: slug === null ? skipToken : () => getMyPlayer(slug),
  })
  return data ?? null
}

/**
 * The player list, searched by name and walked with the keyset cursor the API
 * returns implicitly as the last id. The search term is part of the key, so an
 * answer for the previous search can never land in the current one.
 */
export function usePlayers(slug: string | null, query: string): {
  items: Player[] | null
  loading: boolean
  loadingMore: boolean
  error: PlayersError | null
  hasMore: boolean
  loadMore: () => void
  reload: () => void
} {
  const list = useInfiniteQuery({
    queryKey: playerKeys.list(slug, query),
    queryFn:
      slug === null
        ? skipToken
        : ({ pageParam }) =>
            listPlayers(slug, {
              q: query,
              limit: PLAYER_PAGE,
              ...(pageParam === null ? {} : { cursor: pageParam }),
            }),
    initialPageParam: null as string | null,
    // A short page means the cursor ran out, which is the API's own signal for
    // "nothing more to ask for".
    getNextPageParam: (lastPage) =>
      lastPage.length === PLAYER_PAGE ? lastPage[lastPage.length - 1].id : null,
  })

  return {
    items: list.data === undefined ? null : list.data.pages.flat(),
    loading: slug !== null && list.isPending,
    loadingMore: list.isFetchingNextPage,
    error: list.error === null ? null : settleError(list.error),
    hasMore: list.hasNextPage,
    loadMore: () => {
      // `fetchNextPage` reports a failure through the query's error state, so
      // there is no rejection here to hand to a caller. `cancelRefetch: false`
      // makes a second click on the same page join the read already in flight
      // instead of restarting it: state is not visible until React re-renders,
      // so a guard on state cannot see the first click yet.
      if (list.hasNextPage) settled(list.fetchNextPage({ cancelRefetch: false }))
    },
    reload: () => {
      settled(list.refetch())
    },
  }
}

/** One player with their claim history; the page re-reads after every write. */
export function usePlayerDetail(
  slug: string | null,
  id: string | null,
): {
  player: Player | null
  claims: PlayerClaim[] | null
  loading: boolean
  error: PlayersError | null
  reload: () => void
} {
  const enabled = slug !== null && id !== null
  const player = useQuery({
    queryKey: playerKeys.detail(slug, id),
    queryFn: slug === null || id === null ? skipToken : () => getPlayer(slug, id),
  })
  // The claims are a second read with their own failure: a refused claim list
  // must not hide a player the reader may still see.
  const claims = useQuery({
    queryKey: playerKeys.claims(slug, id),
    queryFn: slug === null || id === null ? skipToken : () => listClaims(slug, id),
  })

  return {
    player: player.data ?? null,
    claims: claims.data ?? null,
    loading: enabled && player.isPending,
    error: player.error === null ? null : settleError(player.error),
    reload: () => {
      settled(player.refetch())
      settled(claims.refetch())
    },
  }
}
