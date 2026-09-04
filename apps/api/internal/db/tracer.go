package db

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// slowQueryThreshold — query lebih lambat dari ini di-log WARN.
const slowQueryThreshold = 200 * time.Millisecond

// maxSQLLogLen — potong SQL yang di-log biar baris log tidak kepanjangan.
const maxSQLLogLen = 200

type queryStartKey struct{}
type querySQLKey struct{}

// slowQueryTracer — pgx.QueryTracer yang mencatat query lambat/error ke slog.
// Berguna untuk menemukan bottleneck (mis. N+1 atau query berat di stats).
type slowQueryTracer struct {
	logger    *slog.Logger
	threshold time.Duration
}

func (t *slowQueryTracer) TraceQueryStart(
	ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData,
) context.Context {
	ctx = context.WithValue(ctx, queryStartKey{}, time.Now())
	return context.WithValue(ctx, querySQLKey{}, data.SQL)
}

func (t *slowQueryTracer) TraceQueryEnd(
	ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData,
) {
	start, _ := ctx.Value(queryStartKey{}).(time.Time)
	sql, _ := ctx.Value(querySQLKey{}).(string)
	elapsed := time.Since(start)

	switch {
	case data.Err != nil:
		t.logger.Warn("db query error",
			"sql", truncateSQL(sql),
			"err", data.Err,
			"duration_ms", elapsed.Milliseconds(),
		)
	case elapsed >= t.threshold:
		t.logger.Warn("slow query",
			"sql", truncateSQL(sql),
			"duration_ms", elapsed.Milliseconds(),
		)
	}
}

func truncateSQL(sql string) string {
	s := strings.Join(strings.Fields(sql), " ") // collapse whitespace
	if len(s) > maxSQLLogLen {
		return s[:maxSQLLogLen] + "..."
	}
	return s
}
