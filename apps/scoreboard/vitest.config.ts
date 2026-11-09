import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  define: {
    __BUILD_STAMP__: JSON.stringify('test-build'),
  },
  plugins: [react()],
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
    setupFiles: ['./src/test/setup.ts'],
    restoreMocks: true,
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/test/**', 'src/**/*.d.ts', 'src/**/*.test.{ts,tsx}'],
      reporter: ['text', 'json-summary', 'json'],
      reportsDirectory: './coverage',
      // Ratchet, see task.d/typescript.sh: every counter carries a floor and
      // only moves up. Measured 2026-11-10 at this commit: lines 97.73,
      // statements 93.04, functions 93.45, branches 85.71. Each floor is the
      // measurement minus the 0.1 point tolerance the gate publishes, so a
      // drop that is bigger than noise fails here (SQ-13).
      thresholds: {
        lines: 97.63,
        statements: 92.94,
        functions: 93.35,
        branches: 85.61,
      },
    },
  },
})