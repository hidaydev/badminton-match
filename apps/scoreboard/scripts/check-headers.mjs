#!/usr/bin/env node
// PWA-10: the scoreboard is a public URL that installs a worker on the origin.
// The deploy config is the only place its headers live, so a missing CSP or
// frame guard is invisible until someone inspects a response. This asserts the
// file before the build is considered done.
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const config = JSON.parse(readFileSync(resolve(here, '..', 'vercel.json'), 'utf8'))

const errors = []

if (/\bnpm\b/.test(`${config.installCommand ?? ''} ${config.buildCommand ?? ''}`)) {
  errors.push('vercel.json still installs or builds with npm')
}
if (!config.installCommand?.includes('--frozen-lockfile')) {
  errors.push('vercel.json does not install with a frozen lockfile')
}
if (!config.buildCommand?.includes('--filter majadu-score build')) {
  errors.push('vercel.json does not build the scoreboard package')
}

const headerKeys = new Set()
for (const block of config.headers ?? []) {
  for (const header of block.headers ?? []) headerKeys.add(header.key)
}
for (const required of [
  'Content-Security-Policy',
  'X-Frame-Options',
  'Referrer-Policy',
  'X-Content-Type-Options',
  'Permissions-Policy',
]) {
  if (!headerKeys.has(required)) errors.push(`missing header ${required}`)
}

const csp = (config.headers ?? [])
  .flatMap(block => block.headers ?? [])
  .find(header => header.key === 'Content-Security-Policy')?.value
if (csp && !csp.includes("frame-ancestors 'none'")) {
  errors.push('CSP is missing frame-ancestors')
}
if (csp && !csp.includes("script-src 'self'")) {
  errors.push('CSP is missing script-src')
}

const noStorePaths = (config.headers ?? [])
  .filter(block => (block.headers ?? []).some(header => header.key === 'Cache-Control' && header.value === 'no-store'))
  .map(block => block.source)
for (const path of ['/', '/index.html']) {
  if (!noStorePaths.includes(path)) errors.push(`${path} is not no-store`)
}

if (errors.length > 0) {
  console.error('headers: vercel.json is missing deploy safety:')
  for (const error of errors) console.error(`  ${error}`)
  process.exit(1)
}

console.log('headers: ok (frozen pnpm install, CSP, frame guard, no-store HTML)')
