// The browser never talks to api.qouver.com directly: HTTP traffic goes through
// a same-origin `/api` path (ADR-021) so the session cookie stays first-party.
// - dev: the proxy below strips `/api` before hitting the local API
// - prod/preview: vercel.json rewrites `/api/:path*` to the API origin
// VITE_API_BASE overrides both (e.g. https://api.qouver.com) for checks that do
// not run behind either proxy; `src/auth/api.ts` reads it.
// E2E_API_PROXY points the proxy at the API the e2e harness started, so the
// browser flow (including the OIDC stub redirect) stays on one origin.
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

const apiProxy = process.env.E2E_API_PROXY ?? 'http://127.0.0.1:8080'

const proxy = {
  '/api': {
    target: apiProxy,
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/api/, ''),
  },
}

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'prompt',
      workbox: {
        maximumFileSizeToCacheInBytes: 3 * 1024 * 1024,
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,ico,png,svg,webp,woff2,webmanifest}'],
        globIgnores: ['team-winner.png', 'anniv-*.png'],
        runtimeCaching: [
          {
            urlPattern: /^https:\/\/fonts\.googleapis\.com\/.*/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'google-fonts-cache',
              expiration: { maxEntries: 10, maxAgeSeconds: 60 * 60 * 24 * 365 },
            },
          },
          {
            urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/i,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'images-cache',
              expiration: { maxEntries: 50, maxAgeSeconds: 60 * 60 * 24 * 30 },
            },
          },
        ],
      },
      manifest: {
        name: 'Majadu App',
        short_name: 'Majadu',
        description: 'Badminton scheduler & tournament manager',
        theme_color: '#020617',
        background_color: '#020617',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: '/logo-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/logo-512.png', sizes: '512x512', type: 'image/png' },
        ],
      },
    }),
  ],
  server: { proxy },
  preview: { port: 4174, strictPort: true, proxy },
})
