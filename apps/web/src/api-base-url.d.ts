// Global build-time constant — di-inject oleh vite.config.ts (`define`).
// Berisi base URL majadu-api (Go backend), mis. "https://api.qouver.com/majadu"
// atau override env VITE_API_URL (mis. "http://localhost:8080" untuk dev lokal).
// Ditentukan saat build dari branch yang di-deploy (VERCEL_GIT_COMMIT_REF).
declare const __API_BASE_URL__: string
