import { execSync } from 'node:child_process'

const arbitraryPatterns = [
  'max-w-\\[[^]]+\\]',
  'min-w-\\[[^]]+\\]',
  'min-h-\\[[^]]+\\]',
  'max-h-\\[[^]]+\\]',
  'z-\\[[^]]+\\]',
]

// Families remapped in `src/index.css` @theme. Anything else resolves to stock
// Tailwind and breaks the single muted palette.
const allowedFamilies = new Set([
  'slate',
  'yellow',
  'amber',
  'indigo',
  'emerald',
  'green',
  'red',
  'sky',
  'blue',
])

const familyPattern = '(bg|text|border|ring|from|to|via|fill|stroke)-([a-z]+)-[0-9]+'

function hasRg() {
  try {
    execSync('rg --version', { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

function search(pattern) {
  const command = hasRg() ? `rg -n --no-heading "${pattern}" src` : `grep -rnE "${pattern}" src`
  try {
    return execSync(command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  } catch (error) {
    if (error?.status === 1) return ''
    throw error
  }
}

function fail(title, output) {
  console.error(title)
  console.error(output)
  process.exit(1)
}

const arbitrary = search(arbitraryPatterns.join('|'))
if (arbitrary) fail('Tailwind arbitrary-value classes found:', arbitrary)

const families = search(familyPattern)
// `border-t-0`, `ring-offset-2` and friends match the shape but are not colours.
const notColours = new Set(['offset', 't', 'r', 'b', 'l', 'x', 'y', 's', 'e'])
const familyExtract = /(?:^|[\s"'`:-])(?:bg|text|border|ring|from|to|via|fill|stroke)-([a-z]+)-[0-9]+/g
const unknown = []
for (const line of families.split('\n')) {
  for (const match of line.matchAll(familyExtract)) {
    if (!notColours.has(match[1]) && !allowedFamilies.has(match[1])) unknown.push(match[1])
  }
}

if (unknown.length > 0) {
  fail(
    'Tailwind palette families outside @theme found (map them in index.css or use a token):',
    [...new Set(unknown)].join('\n'),
  )
}
