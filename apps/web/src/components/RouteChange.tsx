import { useEffect, useRef } from 'react'
import { useLocation, useNavigationType } from 'react-router-dom'

/**
 * Scroll offsets remembered per history entry, so Back returns to the row the
 * user left instead of to the top of the list.
 */
const offsets = new Map<string, number>()

/**
 * The per-screen heading that receives focus after a navigation. Screens
 * without a heading fall back to the layout's `main`, which is focusable for
 * exactly this purpose.
 */
function focusTarget(): HTMLElement | null {
  return (
    document.querySelector<HTMLElement>('main h1') ??
    document.querySelector<HTMLElement>('main')
  )
}

/**
 * Router-level scroll and focus handling. `BrowserRouter` is a declarative
 * router, so there is no `ScrollRestoration` element to mount; this does the
 * two things that one would: a push starts at the top, a pop restores the
 * previous offset, and the new screen is announced by focusing its heading.
 * A screen reader user otherwise gets no signal that the page changed.
 */
export function RouteChange() {
  const location = useLocation()
  const navigation = useNavigationType()
  const entryKey = useRef(location.key)
  const entryOffset = useRef(0)
  const first = useRef(true)

  // Track the offset of the entry currently on screen. The cleanup runs when
  // the key changes, before the next effect, so it records where the user was
  // when they left.
  useEffect(() => {
    entryKey.current = location.key
    entryOffset.current = window.scrollY
    const onScroll = () => {
      entryOffset.current = window.scrollY
    }
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      window.removeEventListener('scroll', onScroll)
      offsets.set(entryKey.current, entryOffset.current)
    }
  }, [location.key])

  useEffect(() => {
    // The first render is a page load, not a navigation: the browser's own
    // restoration decides where to land, and moving focus then would skip the
    // skip link before anyone could use it.
    if (first.current) {
      first.current = false
      return
    }
    window.scrollTo(0, navigation === 'POP' ? offsets.get(location.key) ?? 0 : 0)
    const target = focusTarget()
    if (target === null) return
    target.setAttribute('tabindex', '-1')
    target.focus({ preventScroll: true })
  }, [location.key, navigation])

  return null
}
