import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist']),
  {
    // The base layer is `src/components`; the v1 tree may depend on it, never
    // the other way. The share page is the one new-layer exception left: it
    // imports the shared tally helpers that still live under `legacy/utils`.
    files: ['src/components/**/*.{ts,tsx}', 'src/pages/**/*.{ts,tsx}'],
    // Tests may reach into the legacy store to reset state between cases; the
    // rule is about the direction production code depends on.
    ignores: ['src/pages/SharedSessionPage.tsx', 'src/pages/**/__tests__/**'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['../legacy/*', '../legacy/**', '../../legacy/**', '../../../legacy/**'],
              message: 'src/components and src/pages must not import the legacy tree; invert the dependency instead.',
            },
          ],
        },
      ],
    },
  },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
      // Type aware linting. `no-floating-promises` and `no-misused-promises`
      // need the checker, so every file is resolved through the app tsconfig;
      // `projectService` picks the nearest one per file.
      parserOptions: {
        projectService: {
          // Not part of either tsconfig project (tsc does not build it).
          allowDefaultProject: ['playwright.config.ts'],
        },
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // A promise statement must be awaited or end with a rejection handler.
      // `void` stays allowed: the tree uses it to mark the fire and forget
      // calls whose errors are handled inside the callee.
      '@typescript-eslint/no-floating-promises': 'error',
      // JSX event props may return promises: React ignores the value and the
      // handlers report their own failures. Every other position may not.
      '@typescript-eslint/no-misused-promises': ['error', { checksVoidReturn: { attributes: false } }],
      '@typescript-eslint/no-non-null-assertion': 'error',
    },
  },
  {
    // Type aware rules running on tests would only ask for the same assertion
    // in a different spelling: a fixture the case just built is known to be
    // there, and a missing one fails the assertion that follows anyway.
    files: ['**/*.test.{ts,tsx}', 'src/test/**'],
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off',
    },
  },
])
