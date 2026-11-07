/**
 * Expands a small control's hit area to the 44px touch minimum without
 * changing its visual size or the surrounding layout.
 *
 * The tournament cards are dense: a 28px camera button sits next to a pair
 * name at 402px, so growing the box itself would push the text out. The
 * pseudo-element takes the taps instead. The button keeps its own padding and
 * the parent must not clip overflow.
 */
export const hit44 =
  "relative after:absolute after:left-1/2 after:top-1/2 after:h-11 after:w-11 after:-translate-x-1/2 after:-translate-y-1/2 after:content-['']"