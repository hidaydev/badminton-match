import type { ManifestOptions } from 'vite-plugin-pwa'

/**
 * The web app manifest, in one module so a unit test can assert it without
 * importing the Vite plugin. `vite.config.ts` passes this object through.
 */
export const manifest = {
  name: 'MAJADU Score',
  short_name: 'Score',
  description: 'Badminton scoreboard by MAJADU',
  // A stable install identity: moving start_url or a subpath must not create a
  // second installed app.
  id: '/',
  lang: 'en',
  scope: '/',
  start_url: '/',
  display: 'standalone',
  orientation: 'any',
  background_color: '#020617',
  theme_color: '#020617',
  categories: ['sports', 'utilities'],
  icons: [
    { src: '/logo-192.png', sizes: '192x192', type: 'image/png' },
    { src: '/logo-512.png', sizes: '512x512', type: 'image/png' },
    { src: '/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
  ],
  screenshots: [
    {
      src: '/screenshots/narrow.png',
      sizes: '720x1280',
      type: 'image/png',
      form_factor: 'narrow',
    },
    {
      src: '/screenshots/wide.png',
      sizes: '1280x720',
      type: 'image/png',
      form_factor: 'wide',
    },
  ],
  shortcuts: [{ name: 'Open scoreboard', short_name: 'Score', url: '/' }],
} satisfies Partial<ManifestOptions>
