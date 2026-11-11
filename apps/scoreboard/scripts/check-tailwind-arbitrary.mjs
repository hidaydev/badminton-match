import { execSync } from 'node:child_process'

/**
 * The scoreboard's half of the Tailwind guard (DS-26). It is deliberately the
 * same three rules the web app enforces, minus the palette-family rule: this
 * app does not remap a scale in `@theme`, so a stock family here is not a
 * token leak, it is the app's palette.
 *
 * The rules are written out instead of imported so the two apps can move at
 * their own speed; if the web guard grows a rule the scoreboard should also
 * have, it is added here by hand.
 */
const arbitraryPatterns = [
  'max-w-\\[[^]]+\\]',
  'min-w-\\[[^]]+\\]',
  'min-h-\\[[^]]+\\]',
  'max-h-\\[[^]]+\\]',
  'z-\\[[^]]+\\]',
]

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

const transitionAll = search('transition-all')
if (transitionAll) fail('transition-all found (animate the property, not all of them):', transitionAll)

const disabledOpacity = search('disabled:opacity-')
if (disabledOpacity) fail('inline disabled opacity found (use the shared dim utility):', disabledOpacity)

const panels = search('bg-surface border border-border-subtle')
if (panels) fail('A hand-built panel found (use the shared overlay or Card primitive):', panels)
