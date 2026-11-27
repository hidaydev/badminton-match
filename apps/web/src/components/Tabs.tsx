import { useRef } from 'react'
import type { KeyboardEvent, ReactNode } from 'react'

export type TabItem = {
  id: string
  label: ReactNode
}

export type TabVariant = 'pill' | 'underline'

type TabsProps = {
  items: readonly TabItem[]
  value: string
  onChange: (id: string) => void
  /** Id of the panel the tabs control; each tab points at it. */
  panelId: string
  label: string
  /** Id prefix for the tab buttons. Defaults to `panelId`. */
  idPrefix?: string
  /** `pill` is the filled block; `underline` is a text tab with an accent rule. */
  variant?: TabVariant
  className?: string
  /** Per-site spacing only; the variant owns the look. */
  tabClassName?: (active: boolean) => string
}

const VARIANT: Record<TabVariant, (active: boolean) => string> = {
  pill: (active) =>
    `focus-ring inline-flex min-h-11 items-center text-xs font-semibold px-4 rounded-lg transition-colors ${
      active ? 'bg-accent text-ground' : 'text-fg-dim hover:text-fg'
    }`,
  underline: (active) =>
    `focus-ring inline-flex min-h-11 items-center text-sm font-semibold border-b-2 transition-colors ${
      active ? 'text-accent border-accent' : 'text-fg-dim border-transparent hover:text-fg'
    }`,
}

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
  variant = 'pill',
  className = 'flex gap-1',
  tabClassName,
}: TabsProps) {
  const listRef = useRef<HTMLDivElement>(null)
  const base = VARIANT[variant]

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
        const extra = tabClassName?.(active)
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
            className={`min-h-11 ${base(active)}${extra ? ` ${extra}` : ''}`}
          >
            {item.label}
          </button>
        )
      })}
    </div>
  )
}
