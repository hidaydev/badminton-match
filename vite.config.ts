import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

// ── Backend schema profile per deployment ────────────────────────────────
// App memanggil {VITE_SUPABASE_URL}/rest/v1/rpc/* dengan header Accept-Profile.
// Skema backend beda per environment:
//   - prod (branch main)            → "bm"     (Supabase)
//   - dev (branch ui-revamp)        → "bm_dev" (VPS)
//   - staging (branch supabase-migration) → "bm_dev" (VPS, share schema)
//
// VERCEL_GIT_COMMIT_REF di-inject otomatis oleh Vercel saat build (nama
// branch) — TANPA perlu akses dashboard Vercel. Mapping ini identik di semua
// branch, jadi merge tidak pernah konflik; profile ditentukan saat build.
//
// Override eksplisit via env VITE_SUPABASE_PROFILE (mis. local dev / manual).
const BRANCH_PROFILES: Record<string, string> = {
  main: 'bm',
  'ui-revamp': 'bm_dev',
  'supabase-migration': 'bm_dev',
}

function resolveBackendProfile(env: Record<string, string>): string {
  const explicit = env.VITE_SUPABASE_PROFILE
  if (explicit) return explicit
  const branch = process.env.VERCEL_GIT_COMMIT_REF ?? ''
  // Fail-closed: branch tak dikenal (mis. PR preview) JANGAN diam-diam nembak
  // schema produksi. Default ke bm_dev (dev) — prod hanya branch yang terdaftar.
  return BRANCH_PROFILES[branch] ?? 'bm_dev'
}

export default defineConfig(({ mode }) => {
  // loadEnv baca .env, .env.local, .env.[mode] — tidak seperti process.env
  // yang tidak otomatis di-load untuk kode vite.config.
  const env = loadEnv(mode, process.cwd(), '')
  const backendProfile = resolveBackendProfile(env)
  console.log(`[vite] backend schema profile: ${backendProfile}`)

  return {
    define: {
      // Diganti saat build — identik di semua branch, ditentukan oleh branch
      // yang sedang di-deploy (bukan oleh hasil merge).
      __BACKEND_PROFILE__: JSON.stringify(backendProfile),
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
