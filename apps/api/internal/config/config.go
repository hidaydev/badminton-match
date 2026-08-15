// Package config — konfigurasi runtime dari environment; `.env` di-load
// untuk dev lokal, prod memakai systemd/podman env.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
)

// Config — runtime configuration. Semua nilai dari env; `.env` di-load
// untuk dev lokal (godotenv). Prod memakai systemd/podman env (file 600).
type Config struct {
	// Env — "dev" | "prod". Dev = lenient (default fallback), prod = strict.
	Env string

	// Port HTTP server. Default 8080.
	Port string

	// DatabaseURL — postgres://... koneksi ke Postgres.
	// WAJIB diisi (fail-fast).
	DatabaseURL string

	// DatabaseSchema — schema Postgres yang dipakai (bm / bm_dev).
	// WAJIB: di-set via env, BUKAN hardcode — supaya merge dev→main tidak
	// membawa schema dev ke prod. Dev: bm_dev. Prod: bm.
	DatabaseSchema string

	// AllowedOrigins — daftar origin CORS yang diizinkan (frontend Vercel).
	// Bisa comma-separated; "*" = semua (hanya untuk dev).
	AllowedOrigins []string

	// BaseURL — URL publik API (untuk header Location), mis.
	// https://api.qouver.com/majadu/v1. Kosong = relative path.
	BaseURL string

	// RateLimitPerMin — batas request per menit per IP. 0 = disabled.
	RateLimitPerMin int

	// LogDir — direktori log harian (app-YYYY-MM-DD.log, retensi 7 hari).
	// Kosong = log ke stdout saja (default dev).
	LogDir string

	// LogLevel — "debug" | "info" | "warn". Default info.
	LogLevel string
}

// Load membaca env, me-load .env jika ada, lalu validasi.
// Prod gagal cepat (exit) kalau config wajib tidak ada.
func Load() (Config, error) {
	// .env hanya untuk dev lokal — error diabaikan (file mungkin tidak ada).
	_ = godotenv.Load()

	cfg := Config{
		// Fail-closed: default prod. Environment dev harus eksplisit
		// (MAJADU_ENV=dev) supaya deploy tanpa env tidak mendapat mode lenient.
		Env:  getenv("MAJADU_ENV", "prod"),
		Port: getenv("PORT", "8080"),
	}

	cfg.DatabaseURL = os.Getenv("DATABASE_URL")
	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("DATABASE_URL is required")
	}
	cfg.DatabaseSchema = os.Getenv("MAJADU_DB_SCHEMA")
	if cfg.DatabaseSchema == "" {
		return cfg, fmt.Errorf("MAJADU_DB_SCHEMA is required (bm for prod, bm_dev for dev)")
	}
	cfg.BaseURL = strings.TrimRight(os.Getenv("PUBLIC_BASE_URL"), "/")
	cfg.RateLimitPerMin = atoiDefault(os.Getenv("MAJADU_RATE_LIMIT_PER_MIN"), 120)
	cfg.LogDir = os.Getenv("MAJADU_LOG_DIR")
	cfg.LogLevel = os.Getenv("MAJADU_LOG_LEVEL")

	for _, origin := range splitList(os.Getenv("CORS_ALLOWED_ORIGINS")) {
		cfg.AllowedOrigins = append(cfg.AllowedOrigins, origin)
	}

	if err := cfg.validate(); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func (c Config) validate() error {
	if c.Env != "dev" && c.Env != "prod" {
		return fmt.Errorf("MAJADU_ENV must be 'dev' or 'prod', got %q", c.Env)
	}
	if c.Port == "" {
		return fmt.Errorf("PORT must not be empty")
	}
	if c.Env == "prod" && len(c.AllowedOrigins) == 0 {
		return fmt.Errorf("CORS_ALLOWED_ORIGINS is required in prod")
	}
	return nil
}

// getenv — ambil env key; kosong/absent → fallback.
func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// splitList — pecah string comma-separated, buang bagian kosong.
func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// atoiDefault — parse int; string kosong/invalid/negatif → fallback.
func atoiDefault(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}
