import { execSync } from 'node:child_process'

const patterns = [
  'max-w-\\[[^]]+\\]',
  'min-w-\\[[^]]+\\]',
  'min-h-\\[[^]]+\\]',
  'max-h-\\[[^]]+\\]',
  'z-\\[[^]]+\\]',
]

const command = `rg -n "${patterns.join('|')}" src`

try {
  const output = execSync(command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  if (output) {
    console.error('Tailwind arbitrary-value classes found:')
    console.error(output)
    process.exit(1)
  }
} catch (error) {
  const stdout = error?.stdout?.toString?.().trim?.() ?? ''
  if (stdout) {
    console.error('Tailwind arbitrary-value classes found:')
    console.error(stdout)
    process.exit(1)
  }

  if (error?.status === 1) {
    process.exit(0)
  }

  throw error
}
