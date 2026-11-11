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

// DS-26: three rules that a code review used to have to catch by hand.
//
// `transition-all` animates every property, so a colour change also animates
// the box, the text and the layout around it; the design system animates the
// one property the move is about.
const transitionAll = search('transition-all')
if (transitionAll) {
  fail('transition-all found (animate the property, not all of them):', transitionAll)
}

// The disabled treatment comes from the `disabled-dim` ladder in index.css, so
// the number lives in one place (DS-03).
const disabledOpacity = search('disabled:opacity-')
if (disabledOpacity) {
  fail('inline disabled opacity found (use disabled-dim in index.css):', disabledOpacity)
}

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

// A panel is `Card`. The six class names that make one are a cluster a screen
// copies as a block, which is how nine of them grew: each is a loading
// placeholder rendered before the fetch, and swapping one for a `Card` would
// add a heading slot to a box that shows nothing yet. They are named here one
// by one, so a tenth is a decision and not an accident.
const cards = new Set([
  'src/legacy/pages/RankingsPage.tsx',
  'src/legacy/pages/RatingPlayerPage.tsx',
  'src/legacy/pages/SessionListPage.tsx',
  'src/legacy/pages/TournamentListPage.tsx',
  'src/legacy/pages/TournamentPage.tsx',
])
const panelPattern = 'bg-surface border border-border-subtle'
const panels = search(panelPattern)
const strayPanels = []
let panelCount = 0
for (const line of panels.split('\n')) {
  if (line === '') continue
  panelCount += 1
  const file = line.slice(0, line.indexOf(':'))
  if (!cards.has(file)) strayPanels.push(line)
}
if (strayPanels.length > 0) {
  fail('A hand-built panel outside Card.tsx (use Card, or name the file above):', strayPanels.join('\n'))
}
if (panelCount > 9) {
  fail(`hand-built panels grew past the recorded nine (${panelCount} found)`, panels)
}
