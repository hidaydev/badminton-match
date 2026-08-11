// Global build-time constant — di-inject oleh vite.config.ts (`define`).
// Berisi nama schema PostgREST yang dipakai backend (mis. "bm" atau "bm_dev").
// Ditentukan saat build dari branch yang di-deploy (VERCEL_GIT_COMMIT_REF)
// atau override env VITE_SUPABASE_PROFILE.
declare const __BACKEND_PROFILE__: string
