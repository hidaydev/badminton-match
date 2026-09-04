import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

// ── API base URL per deployment ───────────────────────────────────────────
// Frontend memanggil majadu-api (Go backend) via REST:
//   - prod (branch main) → https://api.qouver.com/majadu        (skema bm)
//   - dev  (branch dev)  → https://api.qouver.com/majadu-dev    (skema bm_dev)
//
// VERCEL_GIT_COMMIT_REF di-inject otomatis oleh Vercel saat build (nama
// branch) — TANPA perlu akses dashboard Vercel. Mapping identik di semua
// branch, jadi merge tidak pernah konflik; URL ditentukan saat build.
//
// Override eksplisit via env VITE_API_URL (mis. local dev → http://localhost:8080).
const BRANCH_API_URLS: Record<string, string> = {
  main: 'https://api.qouver.com/majadu',
  dev: 'https://api.qouver.com/majadu-dev',
}

const DEV_API_URL = 'https://api.qouver.com/majadu-dev'

function resolveApiBaseUrl(env: Record<string, string>): string {
  const explicit = env.VITE_API_URL
  if (explicit) return explicit
  const branch = process.env.VERCEL_GIT_COMMIT_REF ?? ''
  // Fail-closed: branch tak dikenal (mis. PR preview) JANGAN nembak prod.
  return BRANCH_API_URLS[branch] ?? DEV_API_URL
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
