// ── Retry policy untuk request() di endpoints.ts ─────────────────────────
// Pure module: aman diimpor dari test node tanpa mengevaluasi __API_BASE_URL__
// atau fetch. Kebijakan singkat:
//   - read (GET/HEAD/OPTIONS): retry 429/503/500 + network failure (perilaku lama)
//   - mutation (POST/PUT/PATCH/DELETE): retry hanya 429 (rate limit — request
//     belum ter-apply) dan network failure sebelum request terkirim. 5xx tidak
//     di-retry karena server mungkin sudah menulis data (bisa double-apply).

/** HTTP status yang dianggap transient dan boleh di-retry (level transport). */
const RETRYABLE_HTTP_STATUS = new Set([429, 500, 503])

/** HTTP method yang aman untuk diulang (idempotent read). */
const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])

/** Maksimum nilai Retry-After (detik) yang dihormati — cegah menunggu terlalu lama. */
export const MAX_RETRY_AFTER_SECONDS = 10

/**
 * Error untuk kegagalan API.
 * `code`   = kode bisnis dari body error backend (mis. SQLSTATE '40001')
 * `status` = HTTP status asli respons (dipakai untuk keputusan retry)
 */
export class ApiError extends Error {
  code: string | null
  status: number | null
  constructor(message: string, code: string | null = null, status: number | null = null) {
    super(message)
    this.name = 'ApiError'
    this.code = code
    this.status = status
  }
}

/** Apakah error retryable pada level transport (belum mempertimbangkan method). */
export function isRetryableError(error: unknown): boolean {
  if (error instanceof ApiError) {
    return error.status !== null && RETRYABLE_HTTP_STATUS.has(error.status)
  }
  // AbortError/timeout: request mungkin sudah diproses server — jangan retry.
  if (error instanceof DOMException && error.name === 'AbortError') return false
  // TypeError berisi 'fetch': koneksi gagal sebelum request terkirim — aman retry.
  if (error instanceof TypeError && error.message.includes('fetch')) return true
  return false
}

/**
 * Kebijakan retry method-aware.
 * - read: retry 429/503/500 + network failure (TypeError fetch).
 * - mutation: retry hanya 429 dan network failure; 5xx tidak di-retry karena
 *   server mungkin sudah menerapkan write.
 * - `attempt` adalah indeks percobaan (0-based); >= `maxRetries` berarti tidak
 *   ada kesempatan retry lagi.
 */
export function shouldRetry(method: string, error: unknown, attempt: number, maxRetries: number): boolean {
  if (attempt >= maxRetries) return false
  if (!isRetryableError(error)) return false
  // 5xx (bukan 429) untuk mutation: server mungkin sudah apply — no retry.
  if (error instanceof ApiError && error.status !== 429 && !SAFE_METHODS.has(method.toUpperCase())) {
    return false
  }
  return true
}

/**
 * Parse header `Retry-After` (RFC 9110): delta detik numerik atau HTTP-date.
 * Return jumlah detik yang harus ditunggu (dikap ke MAX_RETRY_AFTER_SECONDS),
 * atau null kalau header tidak ada / tidak bisa di-parse.
 */
export function parseRetryAfter(value: string | null | undefined): number | null {
  if (value == null) return null
  const trimmed = value.trim()
  if (trimmed === '') return null

  if (/^\d+$/.test(trimmed)) {
    return Math.min(Number(trimmed), MAX_RETRY_AFTER_SECONDS)
  }

  const dateMs = Date.parse(trimmed)
  if (Number.isNaN(dateMs)) return null
  const seconds = Math.max(0, Math.ceil((dateMs - Date.now()) / 1_000))
  return Math.min(seconds, MAX_RETRY_AFTER_SECONDS)
}
