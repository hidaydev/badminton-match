import { en } from './en'
import type { MessageKey } from './en'

export type { MessageKey }
export { en }

/**
 * Resolve a message key and fill `{name}` placeholders. Unknown keys cannot be
 * passed: `MessageKey` is the union of the dictionary's own keys.
 */
export function t(key: MessageKey, vars?: Record<string, string | number>): string {
  const template: string = en[key]
  if (!vars) return template
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    name in vars ? String(vars[name]) : match,
  )
}
