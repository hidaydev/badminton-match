import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

// ── API base URL per deployment ───────────────────────────────────────────
// Frontend memanggil apps/api (Go backend) via REST. Instance dev sudah
// di-sunset (2026-09-04), jadi prod (https://api.qouver.com/majadu) adalah
// satu-satunya target — untuk semua deployment (main maupun preview).
//
// Override eksplisit via env VITE_API_URL (mis. local dev → http://localhost:8080).
const PROD_API_URL = 'https://api.qouver.com/majadu'

function resolveApiBaseUrl(env: Record<string, string>): string {
  const explicit = env.VITE_API_URL
  if (explicit) return explicit
  return PROD_API_URL
}

export default defineConfig(({ mode }) => {
  // loadEnv baca .env, .env.local, .env.[mode] — tidak seperti process.env
  // yang tidak otomatis di-load untuk kode vite.config.
  const env = loadEnv(mode, process.cwd(), '')
  const apiBaseUrl = resolveApiBaseUrl(env)
  console.log(`[vite] api base url: ${apiBaseUrl}`)

  return {
    define: {
      // Diganti saat build — identik di semua branch, ditentukan oleh branch
      // yang sedang di-deploy (bukan oleh hasil merge).
      __API_BASE_URL__: JSON.stringify(apiBaseUrl),
    },
    plugins: [
      react(),
      tailwindcss(),
      VitePWA({
        registerType: 'prompt',
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
  }
})
