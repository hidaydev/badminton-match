import { useRef } from 'react'
import type { KeyboardEvent, ReactNode } from 'react'

export type TabItem = {
  id: string
  label: ReactNode
}

type TabsProps = {
  items: readonly TabItem[]
  value: string
  onChange: (id: string) => void
  /** Id of the panel the tabs control; each tab points at it. */
  panelId: string
  label: string
  /** Id prefix for the tab buttons. Defaults to `panelId`. */
  idPrefix?: string
  className?: string
  /** Per-site chip styling, given whether the tab is selected. */
  tabClassName?: (active: boolean) => string
}

const DEFAULT_TAB =
  'inline-flex min-h-11 items-center text-xs font-semibold px-4 rounded-lg transition-colors'
const DEFAULT_ACTIVE = 'bg-accent text-ground'
const DEFAULT_INACTIVE = 'text-fg-dim hover:text-fg'

/**
 * One WAI-ARIA tab strip with roving tabindex. The arrow/Home/End handling and
 * the aria wiring live here; a page only says which tab is selected.
 */
export function Tabs({
  items,
  value,
  onChange,
  panelId,
  label,
  idPrefix = panelId,
  className = 'flex gap-1',
  tabClassName,
}: TabsProps) {
  const listRef = useRef<HTMLDivElement>(null)
  const style = tabClassName ?? ((active: boolean) => `${DEFAULT_TAB} ${active ? DEFAULT_ACTIVE : DEFAULT_INACTIVE}`)

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const index = items.findIndex(item => item.id === value)
    if (index < 0) return
    let next: number | null = null
    if (event.key === 'ArrowRight') next = (index + 1) % items.length
    else if (event.key === 'ArrowLeft') next = (index - 1 + items.length) % items.length
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = items.length - 1
    if (next === null) return
    event.preventDefault()
    onChange(items[next].id)
    const tabs = listRef.current?.querySelectorAll<HTMLElement>('[role="tab"]')
    tabs?.[next]?.focus()
  }

  return (
    <div ref={listRef} role="tablist" aria-label={label} className={className} onKeyDown={handleKeyDown}>
      {items.map(item => {
        const active = item.id === value
        return (
          <button
            key={item.id}
            id={`${idPrefix}-${item.id}`}
            type="button"
            role="tab"
            aria-selected={active}
            aria-controls={panelId}
            tabIndex={active ? 0 : -1}
            onClick={() => onChange(item.id)}
            className={`min-h-11 ${style(active)}`}
          >
            {item.label}
          </button>
        )
      })}
    </div>
  )
}
