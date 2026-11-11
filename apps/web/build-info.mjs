// The build stamp: VERSION from the repo root plus the short commit of the tree
// that produced the bundle. Both vite configs read it from here, so the app and
// the tests cannot disagree about what a build is.
//
// No wall clock: the same commit has to produce identical bytes, or the asset
// hashes stop meaning anything. Nothing in this module prints.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('../..', import.meta.url))
const versionFile = fileURLToPath(new URL('../../VERSION', import.meta.url))

function readVersion() {
  try {
    return readFileSync(versionFile, 'utf8').trim()
  } catch {
    return 'unknown'
  }
}

/** A git command against the repo root; throws when git or the repo is absent. */
function git(...args) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim()
}

function readCommit() {
  // Vercel builds from a shallow export where `.git` may be missing; it hands
  // the commit over in the environment instead.
  const fromEnv = process.env.VERCEL_GIT_COMMIT_SHA
  if (fromEnv !== undefined && fromEnv !== '') return fromEnv.slice(0, 7)
  try {
    const sha = git('rev-parse', '--short=7', 'HEAD')
    const dirty = git('status', '--porcelain') !== ''
    return dirty ? `${sha}+dirty` : sha
  } catch {
    return 'unknown'
  }
}

export function buildInfo() {
  return { version: readVersion(), commit: readCommit() }
}
