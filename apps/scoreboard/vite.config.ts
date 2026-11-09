import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'
import { manifest } from './src/manifest'

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'prompt',
      // A classic script in <head> blocks parsing until it is fetched, and the
      // default registration waits for `load`. Deferring costs nothing.
      injectRegister: 'script-defer',
      // The logo icons come from `globPatterns`; letting the plugin add them a
      // second time only duplicates the precache entries (PWA-16).
      includeManifestIcons: false,
      workbox: {
        // The board is installed over the worst network in the building. 512 KiB
        // is the documented ceiling (PWA-18); the total is asserted separately.
        maximumFileSizeToCacheInBytes: 512 * 1024,
        navigateFallback: '/index.html',
        // A navigation to the API must reach the server, never the cached shell;
        // otherwise an offline API call looks like a document load.
        navigateFallbackDenylist: [/^\/api\//, /^\/ws/],
        globPatterns: ['**/*.{js,css,html,ico,png,svg,jpeg,webmanifest}'],
        // The manifest body is injected by the plugin; ignoring it here keeps
        // one entry instead of two.
        // `majadu-logo.png` is never rendered; the install sheet uses logo-192.
        // `logo-512.png` is a manifest icon the installer fetches, not something
        // the offline shell draws, so it does not buy a slot in the precache.
        globIgnores: ['manifest.webmanifest', 'majadu-logo.png', 'logo-512.png'],
      },
      manifest,
    }),
  ],
})
