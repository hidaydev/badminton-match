import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      'virtual:pwa-register/react': new URL('./src/test/pwa-register.ts', import.meta.url).pathname,
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
      // Ratchet, see task.d/typescript.sh: raise this as coverage lands, never
      // lower it. The per-file rows in coverage/coverage-summary.json are what
      // catch one file regressing behind a rising total.
      thresholds: {
        lines: 54,
      },
    },
  },
})
