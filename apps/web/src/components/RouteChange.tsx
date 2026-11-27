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
  // Where the user was when they asked to leave. The browser clamps the scroll
  // offset as soon as the destination renders shorter than the current one, and
  // that clamp fires a scroll event before this entry's cleanup runs, so the
  // live offset is no longer the one to remember. Capturing it on the way out
  // is what keeps a Back from a short screen landing at the wrong row.
  const departure = useRef<number | null>(null)
  const first = useRef(true)

  // Track the offset of the entry currently on screen. The cleanup runs when
  // the key changes, before the next effect, so it records where the user was
  // when they left.
  useEffect(() => {
    const key = location.key
    entryKey.current = key
    entryOffset.current = window.scrollY
    departure.current = null

    const onScroll = () => {
      // A scroll that arrives after the click belongs to the destination and is
      // clamped to its height, not to where the user left.
      if (departure.current !== null) return
      entryOffset.current = window.scrollY
    }
    // Capture phase, so the snapshot is taken before the router swaps the
    // screen. `click` also covers a link activated by keyboard.
    const rememberDeparture = () => {
      if (departure.current !== null) return
      departure.current = window.scrollY
    }
    const onPopState = () => {
      // Not `window.scrollY`: by the time a pop lands, the browser may already
      // have clamped this entry to the destination's height. The last tracked
      // offset is still this entry's own.
      if (departure.current !== null) return
      departure.current = entryOffset.current
    }

    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('popstate', onPopState)
    document.addEventListener('pointerdown', rememberDeparture, true)
    document.addEventListener('click', rememberDeparture, true)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('popstate', onPopState)
      document.removeEventListener('pointerdown', rememberDeparture, true)
      document.removeEventListener('click', rememberDeparture, true)
      offsets.set(key, departure.current ?? entryOffset.current)
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
