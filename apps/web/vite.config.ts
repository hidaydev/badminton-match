// nAPI_BASE overrides both (e.g. https://api.qouver.com) for checks that do
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The browser never talks to api.qouver.com directly: HTTP traffic goes through
// a same-origin `/api` path (ADR-021) so the session cookie stays first-party.
// - dev: the proxy below strips `/api` before hitting the local API
// - prod/preview: vercel.json rewrites `/api/:path*` to the API origin
// VITE_API_BASE overrides both (e.g. https://api.qouver.com) for checks that do
// not run behind either proxy; `src/auth/api.ts` reads it.
// E2E_API_PROXY points the proxy at the API the e2e harness started, so the
// browser flow (including the OIDC stub redirect) stays on one origin.
const apiProxy = process.env.E2E_API_PROXY ?? 'http://127.0.0.1:8080'

const proxy = {
  '/api': {
    target: apiProxy,
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/api/, ''),
  },
}

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { proxy },
  preview: { port: 4174, strictPort: true, proxy },
})
