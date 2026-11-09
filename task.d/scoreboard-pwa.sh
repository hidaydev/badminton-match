#!/bin/sh
# PWA-03: the hall scoreboard must ship an installable service worker. This
# asserts the built tree, not the source: the precache has to contain the shell
# and the entry chunk that the built index.html references.
#
#   pnpm build:scoreboard && ./task scoreboard-pwa
set -eu

. "$(dirname "$0")/lib.sh"

require_cmd node

DIST="$REPO_ROOT/apps/scoreboard/dist"
[ -f "$DIST/sw.js" ] || fail "$DIST/sw.js is missing: run pnpm build:scoreboard first"
[ -f "$DIST/index.html" ] || fail "$DIST/index.html is missing: run pnpm build:scoreboard first"

DIST="$DIST" node <<'NODE'
const fs = require('node:fs');
const dist = process.env.DIST;
const sw = fs.readFileSync(`${dist}/sw.js`, 'utf8');
const html = fs.readFileSync(`${dist}/index.html`, 'utf8');
const script = html.match(/<script[^>]*\bsrc=["']([^"']+\.js)["']/);
if (!script) throw new Error(`${dist}/index.html has no entry script`);
const entry = script[1].replace(/^\//, '');
const urls = [...sw.matchAll(/["']?url["']?\s*:\s*["']([^"']+)["']/g)]
  .map((match) => match[1].replace(/^\//, ''));
if (!urls.includes('index.html')) {
  throw new Error(`${dist}/sw.js precache has no /index.html`);
}
if (!urls.includes(entry)) {
  throw new Error(`${dist}/sw.js precache has no entry script ${entry}`);
}
console.log(`scoreboard precache ok: /index.html and ${entry}`);
NODE
