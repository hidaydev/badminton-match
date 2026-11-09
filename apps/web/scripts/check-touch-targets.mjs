import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Every `<button>` must carry the 44px touch floor. Dense rows keep their
 * visual size and use `hit44`, which expands the hit area with a pseudo
 * element; ordinary buttons use `min-h-11`/`h-11`. The rule is enforced here
 * because a class string cannot be typed.
 */
const MARKERS = ['min-h-11', 'h-11', 'hit44']
const roots = ['src']

function files(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...files(path))
    else if (entry.name.endsWith('.tsx') && !entry.name.includes('.test.')) out.push(path)
  }
  return out
}

/** Returns the index just past the opening `>` of the tag starting at `start`. */
function tagEnd(text, start) {
  let depth = 0
  let quote = null
  for (let i = start; i < text.length; i += 1) {
    const char = text[i]
    if (quote !== null) {
      if (char === quote && text[i - 1] !== '\\') quote = null
      continue
    }
    if (char === '"' || char === "'" || char === '`') {
      quote = char
      continue
    }
    if (char === '{') depth += 1
    else if (char === '}') depth -= 1
    else if (char === '>' && depth === 0) return i + 1
  }
  return -1
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length
}

const offenders = []
for (const root of roots) {
  for (const file of files(root)) {
    const text = readFileSync(file, 'utf8')
    let cursor = 0
    for (;;) {
      const start = text.indexOf('<button', cursor)
      if (start === -1) break
      const end = tagEnd(text, start + '<button'.length)
      if (end === -1) break
      const tag = text.slice(start, end)
      if (!MARKERS.some((marker) => tag.includes(marker))) {
        offenders.push(`${file}:${lineOf(text, start)}`)
      }
      cursor = end
    }
  }
}

if (offenders.length > 0) {
  console.error('Buttons below the 44px touch floor (add min-h-11, h-11 or hit44):')
  console.error(offenders.join('\n'))
  process.exit(1)
}
