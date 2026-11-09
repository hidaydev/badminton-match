// The browser never talks to api.qouver.com directly: HTTP traffic goes through
// a same-origin `/api` path (ADR-021) so the session cookie stays first-party.
// - dev: the proxy below strips `/api` before hitting the local API
// - prod/preview: vercel.json rewrites `/api/:path*` to the API origin
// VITE_API_BASE overrides both (e.g. https://api.qouver.com) for checks that do
// not run behind either proxy; `src/auth/api.ts` reads it.
// E2E_API_PROXY points the proxy at the API the e2e harness started, so the
// browser flow (including the OIDC stub redirect) stays on one origin.
import { fileURLToPath } from 'node:url'
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
  // The session socket upgrades on the API origin; in dev the proxy keeps it
  // on the same port as the rest of the app.
  '/ws': {
    target: apiProxy,
    changeOrigin: true,
    ws: true,
  },
}

export default defineConfig({
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'prompt',
      // Registration lives in `src/App.tsx` (`useRegisterSW`), so the plugin has
      // nothing to inject. Pinned off instead of left on `auto` so a later
      // registerType change cannot add a second, inline registration script to
      // index.html: the CSP allows `script-src 'self'` and no inline script.
      injectRegister: false,
      // The logo icons come from `globPatterns`; letting the plugin add them a
      // second time only duplicates the precache entries.
      includeManifestIcons: false,
      workbox: {
        // Precaching is the app shell only. Anything heavier than this (the
        // social-export backgrounds, team photos) is fetched on demand by the
        // runtime rules below instead of on the first install.
        maximumFileSizeToCacheInBytes: 320 * 1024,
        navigateFallback: '/index.html',
        // The API shares this origin under /api: a navigation there (the OIDC
        // callback) must reach the server, never the cached app shell.
        navigateFallbackDenylist: [/^\/api\//],
        globPatterns: ['**/*.{js,css,html,ico,svg,webmanifest}', 'logo-*.png', 'fonts/*.woff2', '*.ttf'],
        // The manifest body is injected by vite-plugin-pwa itself; ignoring it
        // here keeps one precache entry instead of two.
        globIgnores: ['team-winner.png', 'anniv-*.png', 'manifest.webmanifest'],
        runtimeCaching: [
          {
            // Public asset paths only. The cache is origin-wide, so a rule that
            // matched every image would outlive logout and hand one account's
            // image to the next user of a shared tablet (PWA-25).
            urlPattern: /\/(?:assets\/[^/]+|logo-[^/]+)\.(?:png|jpe?g|svg|gif|webp)$/i,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'images-cache',
              expiration: { maxEntries: 50, maxAgeSeconds: 60 * 60 * 24 * 30 },
            },
          },
          {
            // PWA-23: the decorative TTFs are precached too; this is the
            // backstop for a font change that lands between deploys.
            urlPattern: /\.(?:woff2|ttf)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'fonts-cache',
              expiration: { maxEntries: 12, maxAgeSeconds: 60 * 60 * 24 * 365 },
            },
          },
        ],
      },
      manifest: {
        name: 'MAJADU App',
        short_name: 'MAJADU',
        description: 'Badminton scheduler & tournament manager',
        // Same ground as `--color-ground` in index.css and the `<meta
        // name="theme-color">` in index.html: installers and the browser chrome
        // must not disagree with the app behind them.
        lang: 'en',
        scope: '/',
        theme_color: '#0b0e13',
        background_color: '#0b0e13',
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
  build: {
    // The service worker only precaches chunks under 200 KB (see the PWA
    // config above), so the dependencies get their own chunks. Only vendor
    // code is grouped: a size-split group for `src/legacy` mixed eagerly and
    // lazily imported modules into one chunk, which dragged the summary modal
    // (and dnd-kit with it) back into the first load.
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            { name: 'vendor', test: /[\\/]node_modules[\\/]/, maxSize: 180 * 1024 },
          ],
        },
      },
    },
  },
})
