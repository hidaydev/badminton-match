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
    },
  },
])
