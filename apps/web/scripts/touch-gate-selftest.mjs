#!/usr/bin/env node
/**
 * The negative test for the touch gate: prove it fails when the rule is gone.
 *
 * A gate that only ever passes is indistinguishable from a gate that cannot
 * fail. This takes the real built stylesheet of `apps/web`, removes the
 * `.hit44` rules from a copy of it, and asserts that
 * `check-touch-targets.mjs --app web --dist <copy>` exits 1 for the reason the
 * gate exists. The same copy untouched must exit 0, so the test cannot pass by
 * making the gate always fail.
 *
 * It reads the artifact instead of rebuilding a mutated `index.css`: that keeps
 * the negative case fast and, more importantly, keeps it from writing to the
 * tree while somebody else may be building. `./task check` is the run that
 * exercises the real build.
 *
 *   node scripts/touch-gate-selftest.mjs
 */
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '../../..')
const GATE = join(HERE, 'check-touch-targets.mjs')
const DIST = join(REPO_ROOT, 'apps/web/dist/assets')

const files = readdirSync(DIST).filter((name) => name.endsWith('.css'))
if (files.length === 0) {
  console.error(`${DIST} holds no .css: build the web app first (./task check does)`)
  process.exit(1)
}

const built = files.map((name) => readFileSync(join(DIST, name), 'utf8')).join('\n')
if (!/\.hit44\b/.test(built)) {
  console.error(`.hit44 is already absent from ${DIST}: this tree is the failure case, not a baseline`)
  process.exit(1)
}

const work = mkdtempSync(join(tmpdir(), 'touch-gate-'))
const run = (dir) =>
  spawnSync(process.execPath, [GATE, '--app', 'web', '--dist', dir], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })

try {
  // Control: the untouched copy passes, so a failure below is about `.hit44`.
  const clean = join(work, 'clean')
  mkdirSync(clean)
  writeFileSync(join(clean, 'app.css'), built)
  const control = run(clean)
  if (control.status !== 0) {
    console.error('control run failed: the gate rejects a clean artifact')
    console.error(control.stderr.trim())
    process.exit(1)
  }

  // The failure the gate exists for: the class is rendered, the rule is not.
  const broken = join(work, 'broken')
  mkdirSync(broken)
  const withoutHit44 = built
    .replace(/\.hit44(?::?:?[a-z-]+)?[^{]*\{[^}]*\}/g, '')
    .replace(/\.hit44\{[^}]*\}/g, '')
  if (/\.hit44\b/.test(withoutHit44)) {
    console.error('could not remove .hit44 from the copy; the negative test is not testing anything')
    process.exit(1)
  }
  writeFileSync(join(broken, 'app.css'), withoutHit44)
  const negative = run(broken)
  if (negative.status === 0) {
    console.error('the gate passed a stylesheet with no .hit44 rule: it has no teeth')
    process.exit(1)
  }
  if (!negative.stderr.includes('.hit44')) {
    console.error('the gate failed, but not on .hit44:')
    console.error(negative.stderr.trim())
    process.exit(1)
  }
  console.log('touch gate self-test: ok (clean artifact passes, artifact without .hit44 fails on .hit44)')
} finally {
  rmSync(work, { recursive: true, force: true })
}
