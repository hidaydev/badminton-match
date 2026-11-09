import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      'virtual:pwa-register/react': new URL('./src/test/pwa-register.ts', import.meta.url).pathname,
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
    setupFiles: ['./src/test/setup.ts'],
    restoreMocks: true,
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/test/**', 'src/i18n/en.ts', 'src/**/*.d.ts', 'src/**/*.test.{ts,tsx}'],
      reporter: ['text', 'json-summary', 'json'],
      reportsDirectory: './coverage',
      // Ratchet, see task.d/typescript.sh: raise these as coverage lands, never
      // lower them. Measured on 2026-11-10 at this commit: lines 60.25,
      // functions 50.95, branches 47.93, statements 57.91. Each floor is the
      // measurement minus the 0.1 point tolerance the gate publishes, so a drop
      // bigger than noise fails here (SQ-13).
      //
      // `perFile` in the object form checks the aggregate against the four
      // numbers above and every file against its own minimum. A global per-file
      // minimum would fail the 55 legacy files that no test imports yet, so the
      // non-zero per-file floors are the behaviour-carrying trees in the glob
      // entries below. Deleting every test for one page drops that file to 0%
      // and fails its glob.
      thresholds: {
        lines: 60.15,
        functions: 50.85,
        branches: 47.83,
        statements: 57.81,
        perFile: {
          lines: 0,
          functions: 0,
          branches: 0,
          statements: 0,
        },
        'src/pages/**': {
          lines: 33,
          functions: 0,
          branches: 50,
          statements: 33,
          perFile: true,
        },
        // The primitives are the widest blast radius in the app and each one
        // now has a test file. Lines and functions are pinned at 100 so losing
        // a test case fails the gate, not only the aggregate.
        'src/components/**': {
          lines: 100,
          functions: 100,
          branches: 50,
          statements: 92,
          perFile: true,
        },
        'src/players/**': {
          lines: 96,
          functions: 92,
          branches: 85,
          statements: 90,
          perFile: true,
        },
        'src/legacy/hooks/**': {
          lines: 28,
          functions: 16,
          branches: 0,
          statements: 25,
          perFile: true,
        },
      },
    },
  },
})
