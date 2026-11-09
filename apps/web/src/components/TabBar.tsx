/* eslint-disable react-refresh/only-export-components */
import { useRef, type KeyboardEvent, type ReactNode } from 'react'

export type TabItem<Id extends string> = { id: Id; label: ReactNode }

export function tabId(idPrefix: string, id: string): string {
  return `${idPrefix}-tab-${id}`
}

export function tabPanelId(idPrefix: string): string {
  return `${idPrefix}-panel`
}

type Props<Id extends string> = {
  items: readonly TabItem<Id>[]
  value: Id
  onChange: (id: Id) => void
  /** Accessible name for the whole tab set. */
  label: string
  /** Prefix shared by every tab id and the panel id (`tabId`, `tabPanelId`). */
  idPrefix: string
  className?: string
  /** The screen's own look; the behaviour and the roles live here. */
  tabClassName: (item: TabItem<Id>, selected: boolean) => string
}

/**
 * The one tab bar in the app. It was written first on the shared session
 * screen; the tournament screen exposed the same visual control as three
 * unrelated buttons, so assistive technology could not tell which view was
 * active. Arrow keys, Home/End, a roving tab stop and the tab-to-panel
 * association now ship with the bar instead of with each screen.
 */
export function TabBar<Id extends string>({
  items,
  value,
  onChange,
  label,
  idPrefix,
  className,
  tabClassName,
}: Props<Id>) {
  const list = useRef<HTMLDivElement>(null)

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const current = items.findIndex((item) => item.id === value)
    let next: number
    switch (event.key) {
      case 'ArrowRight':
        next = (current + 1) % items.length
        break
      case 'ArrowLeft':
        next = (current - 1 + items.length) % items.length
        break
      case 'Home':
        next = 0
        break
      case 'End':
        next = items.length - 1
        break
      default:
        return
    }
    event.preventDefault()
    onChange(items[next].id)
    const tabs = list.current?.querySelectorAll<HTMLElement>('[role="tab"]')
    tabs?.[next]?.focus()
  }

  return (
    <div ref={list} role="tablist" aria-label={label} onKeyDown={onKeyDown} className={className}>
      {items.map((item) => {
        const selected = item.id === value
        return (
          <button
            key={item.id}
            id={tabId(idPrefix, item.id)}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls={tabPanelId(idPrefix)}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(item.id)}
            className={`hit44 ${tabClassName(item, selected)}`}
          >
            {item.label}
          </button>
        )
      })}
    </div>
  )
}
