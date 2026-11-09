#!/usr/bin/env node
// Fails when the generated TypeScript types no longer describe the contract.
//
// `packages/web-client/src/api.ts` is generated from the component schemas in
// `packages/contracts/openapi/api.yaml`, and the app imports those interfaces.
// A field removed from the contract has to fail `check:types` even when nobody
// ran the generator: this reads both artefacts and compares them.
//
// Usage: node scripts/check-contract-types.mjs [--contract PATH] [--client PATH]

import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')

function argument(name, fallback) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : fallback
}

const contractPath = resolve(
  argument('--contract', join(repoRoot, 'packages/contracts/openapi/api.yaml')),
)
const clientPath = resolve(
  argument('--client', join(repoRoot, 'packages/web-client/src/api.ts')),
)

/** `export interface Name {` ... `}` blocks, in emission order. */
function parseInterfaces(source) {
  const interfaces = new Map()
  let current = null
  for (const line of source.split('\n')) {
    const open = line.match(/^export interface (\w+) \{$/)
    if (open) {
      current = { name: open[1], properties: new Map() }
      interfaces.set(current.name, current)
      continue
    }
    if (current === null) continue
    if (line === '}') {
      current = null
      continue
    }
    const property = line.match(/^ {2}([A-Za-z_$][\w$]*)(\??): /)
    if (property) {
      current.properties.set(property[1], { optional: property[2] === '?' })
    }
  }
  return interfaces
}

function main() {
  const document = JSON.parse(readFileSync(contractPath, 'utf8'))
  const interfaces = parseInterfaces(readFileSync(clientPath, 'utf8'))
  const problems = []

  for (const [name, schema] of Object.entries(document.components?.schemas ?? {})) {
    const generated = interfaces.get(name)
    if (generated === undefined) {
      problems.push(`missing interface ${name} for schema ${name}`)
      continue
    }
    const required = new Set(schema.required ?? [])
    for (const property of Object.keys(schema.properties ?? {})) {
      const field = generated.properties.get(property)
      if (field === undefined) {
        problems.push(`${name}.${property} is in the contract but not in the types`)
        continue
      }
      if (required.has(property) === field.optional) {
        problems.push(
          `${name}.${property} is ${required.has(property) ? 'required' : 'optional'} ` +
            `in the contract and ${field.optional ? 'optional' : 'required'} in the types`,
        )
      }
    }
    for (const property of generated.properties.keys()) {
      if (!(property in (schema.properties ?? {})) && property !== '[key: string]') {
        problems.push(`${name}.${property} is in the types but no longer in the contract`)
      }
    }
  }

  if (problems.length > 0) {
    for (const problem of problems) {
      console.error(`contract-types: ${problem}`)
    }
    console.error('contract-types: run ./task contract-gen and update the app')
    process.exit(1)
  }
  console.log(
    `contract-types: ok (${Object.keys(document.components?.schemas ?? {}).length} schemas)`,
  )
}

main()
