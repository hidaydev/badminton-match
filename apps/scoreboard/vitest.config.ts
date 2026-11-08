import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
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
      // Ratchet, see task.d/typescript.sh. The measured baseline is 97.4% of
      // 154 executable lines; raise this as coverage lands, never lower it.
      thresholds: {
        lines: 97,
      },
    },
  },
})