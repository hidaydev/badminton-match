// Package db — koneksi pool Postgres (pgxpool) dengan search_path per schema.
package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// NewPool membuat koneksi pool ke Postgres, memverifikasi dengan Ping, dan
// mengarahkan search_path ke schema target (bm / bm_dev) per-koneksi.
// Schema di-set via config (env), BUKAN hardcode — sehingga kueri di store
// tidak perlu prefix schema dan merge branch dev→main aman dari schema leak.
func NewPool(ctx context.Context, databaseURL, schema string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	// Ukuran pool kecil — cukup untuk tool skala kecil.
	cfg.MaxConns = 10
	cfg.MinConns = 1
	// search_path per koneksi: schema target dulu, lalu public.
	cfg.ConnConfig.RuntimeParams["search_path"] = fmt.Sprintf("%s, public", schema)

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}
