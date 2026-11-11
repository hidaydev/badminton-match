// SQ-11: the rule that makes `void promise.then(...)` fail has to be proven,
// not declared. This writes the DoD snippet into the tree, runs the same eslint
// the gate uses, and requires exactly that failure; then it rewrites the file in
// the awaited shape and requires a pass, so a config that quietly stopped
// linting the path cannot pass as "the rule fired".
import { execFileSync } from 'node:child_process'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const webRoot = dirname(here)
const probeDir = join(webRoot, 'src', '__lint_probe__')
const probe = join(probeDir, 'void_promise.ts')
const eslint = join(webRoot, 'node_modules', '.bin', 'eslint')

const floating = `declare function loadOverlayImages(input: Record<string, never>): Promise<void>

export function probe(): void {
  void loadOverlayImages({}).then(() => undefined)
}
`

const awaited = `declare function loadOverlayImages(input: Record<string, never>): Promise<void>

export async function probe(): Promise<void> {
  await loadOverlayImages({}).then(() => undefined)
}
`

/** The lint verdict on the probe file alone, with eslint's own exit status. */
function lint() {
  try {
    const stdout = execFileSync(eslint, [probe], {
      cwd: webRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    return { code: 0, output: stdout }
  } catch (error) {
    const stdout = typeof error.stdout === 'string' ? error.stdout : ''
    const stderr = typeof error.stderr === 'string' ? error.stderr : ''
    return { code: typeof error.status === 'number' ? error.status : 1, output: stdout + stderr }
  }
}

mkdirSync(probeDir, { recursive: true })
try {
  writeFileSync(probe, floating)
  const rejected = lint()
  if (rejected.code === 0) {
    console.error('lint-rule: `void promise.then(...)` passed, so the rule is not in force')
    process.exit(1)
  }
  if (!rejected.output.includes('no-floating-promises')) {
    console.error(`lint-rule: the snippet failed for another reason:\n${rejected.output}`)
    process.exit(1)
  }

  writeFileSync(probe, awaited)
  const accepted = lint()
  if (accepted.code !== 0) {
    console.error(`lint-rule: the awaited form failed:\n${accepted.output}`)
    process.exit(1)
  }

  console.log('lint-rule: ok (void promise rejected, awaited form accepted)')
} finally {
  rmSync(probeDir, { recursive: true, force: true })
}
