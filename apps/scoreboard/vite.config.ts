import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'prompt',
      // The logo icons come from `globPatterns`; letting the plugin add them a
      // second time only duplicates the precache entries (PWA-16).
      includeManifestIcons: false,
      workbox: {
        maximumFileSizeToCacheInBytes: 3 * 1024 * 1024,
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,ico,png,svg,jpeg,webmanifest}'],
        // The manifest body is injected by the plugin; ignoring it here keeps
        // one entry instead of two.
        // `majadu-logo.png` is never rendered; the install sheet uses logo-192.
        // `logo-512.png` is a manifest icon the installer fetches, not something
        // the offline shell draws, so it does not buy a slot in the precache.
        globIgnores: ['manifest.webmanifest', 'majadu-logo.png', 'logo-512.png'],
      },
      manifest: {
        name: 'MAJADU Score',
        short_name: 'Score',
        description: 'Badminton scoreboard by MAJADU',
        theme_color: '#020617',
        background_color: '#020617',
        display: 'standalone',
        orientation: 'any',
        start_url: '/',
        icons: [
          { src: '/logo-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/logo-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
    }),
  ],
})
