import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The browser never talks to api.qouver.com directly: HTTP traffic goes through
// a same-origin `/api` path (ADR-021) so the session cookie stays first-party.
// - dev: the proxy below strips `/api` before hitting the local API
// - prod/preview: vercel.json rewrites `/api/:path*` to the API origin
// VITE_API_BASE overrides both (e.g. https://api.qouver.com) for checks that do
// not run behind either proxy; `src/auth/api.ts` reads it.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8080',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
})
