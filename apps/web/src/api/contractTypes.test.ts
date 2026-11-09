import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// Vitest runs with the package directory as the working directory.
const script = join(process.cwd(), 'scripts/check-contract-types.mjs')

type Contract = {
  components: {
    schemas: Record<
      string,
      { type: string; required?: string[]; properties: Record<string, unknown> }
    >
  }
}

function contract(required: string[], properties: string[]): Contract {
  return {
    components: {
      schemas: {
        Member: {
          type: 'object',
          required,
          properties: Object.fromEntries(
            properties.map((name) => [name, { type: 'string' }]),
          ),
        },
      },
    },
  }
}

function run(contractBody: Contract, interfaceBody: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'contract-types-'))
  const contractPath = join(dir, 'api.yaml')
  const clientPath = join(dir, 'api.ts')
  writeFileSync(contractPath, JSON.stringify(contractBody))
  writeFileSync(clientPath, interfaceBody)
  return execFileSync(
    process.execPath,
    [script, '--contract', contractPath, '--client', clientPath],
    { encoding: 'utf8', stdio: 'pipe' },
  )
}

describe('check-contract-types', () => {
  it('accepts the committed tree', () => {
    const output = execFileSync(process.execPath, [script], { encoding: 'utf8' })
    expect(output).toContain('contract-types: ok')
  })

  it('fails when a contract property is missing from the interface', () => {
    expect(() =>
      run(
        contract(['userId'], ['userId', 'displayName']),
        'export interface Member {\n  userId: string;\n}\n',
      ),
    ).toThrowError(/Member\.displayName is in the contract but not in the types/)
  })

  it('fails when a property is optional in one and required in the other', () => {
    expect(() =>
      run(
        contract(['userId'], ['userId']),
        'export interface Member {\n  userId?: string;\n}\n',
      ),
    ).toThrowError(/Member\.userId is required in the contract and optional in the types/)
  })
})
