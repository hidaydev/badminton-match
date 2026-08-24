package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"majadu-api/internal/config"
	"majadu-api/internal/db"
	"majadu-api/internal/handler"
	"majadu-api/internal/logfile"
	"majadu-api/internal/middleware"
	"majadu-api/internal/store"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	// Fail-fast: prod harus punya config lengkap.
	cfg, err := config.Load()
	if err != nil {
		slog.Error("config error", "error", err)
		os.Exit(1)
	}

	// Logger: stdout default; kalau MAJADU_LOG_DIR di-set → file harian
	// (app-YYYY-MM-DD.log, retensi 7 hari — ala catalina.out).
	var logCloser func() error
	var logOut io.Writer = os.Stdout
	if cfg.LogDir != "" {
		w, err := logfile.New(cfg.LogDir, 7)
		if err != nil {
			slog.Error("log file init failed", "error", err)
			os.Exit(1)
		}
		logOut = w
		logCloser = w.Close
	}
	logger := slog.New(slog.NewTextHandler(logOut, &slog.HandlerOptions{
		Level: parseLogLevel(cfg.LogLevel),
	}))
	if logCloser != nil {
		defer func() { _ = logCloser() }()
	}

	// Context dibatalkan saat SIGINT/SIGTERM; dipakai juga untuk
	// memberhentikan janitor rate limiter saat shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL, cfg.DatabaseSchema, logger)
	if err != nil {
		logger.Error("database connection failed", "error", err)
		os.Exit(1)
	}
	defer pool.Close()
	logger.Info("database connected")

	// Satu instance SessionStore dipakai handler + ticker — watchers SSE
	// (Subscribe/Broadcast) per-instance; kalau ticker pakai instance terpisah,
	// broadcast auto-lock tidak sampai ke client yang sedang membuka sesi
	// (bug #2 RC-B — harus manual refresh).
	sessionStore := store.NewSessionStore(pool, cfg.DatabaseSchema)

	mux := http.NewServeMux()
	h := registerRoutes(mux, logger, cfg, pool, ctx, sessionStore)

	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      h,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Ticker auto-lock: sesi draft yang tanggalnya lewat → locked (gate data
	// final untuk rating ingest; ABSENT_TBD_PLAYERS_DESIGN.md §4.6).
	{
		locker := sessionStore
		autoLockCtx, cancelAutoLock := context.WithCancel(ctx)
		defer cancelAutoLock()
		go func() {
			run := func() {
				runCtx, cancel := context.WithTimeout(autoLockCtx, 2*time.Minute)
				defer cancel()
				n, err := locker.AutoLockExpiredSessions(runCtx)
				if err != nil {
					logger.Error("auto-lock gagal", "error", err)
					return
				}
				if n > 0 {
					logger.Info("auto-lock", "sessions_locked", n)
				}
				// Auto-ingest sesi yang sudah final (locked) tapi belum diingest.
				// Dijalankan unconditionally — tidak hanya saat ticker mengunci
				// session baru, karena save-path auto-lock juga bisa mengunci
				// session tanpa melalui ticker (audit H2 fix).
				ni, err := locker.AutoIngestLockedSessions(runCtx)
				if err != nil {
					logger.Error("auto-ingest gagal", "error", err)
					return
				}
				if ni > 0 {
					logger.Info("auto-ingest", "sessions_ingested", ni)
				}
			}
			ticker := time.NewTicker(30 * time.Minute)
			defer ticker.Stop()
			run() // sekali saat start
			for {
				select {
				case <-ticker.C:
					run()
				case <-autoLockCtx.Done():
					return
				}
			}
		}()
	}

	go func() {
		logger.Info("server listening", "addr", srv.Addr, "env", cfg.Env)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown.
	<-ctx.Done()
	logger.Info("shutting down...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "error", err)
	}
}

func registerRoutes(mux *http.ServeMux, logger *slog.Logger, cfg config.Config, pool *pgxpool.Pool, ctx context.Context, sessionStore *store.SessionStore) http.Handler {
	health := &handler.HealthHandler{Pool: pool}
	mux.Handle("GET /healthz", http.HandlerFunc(health.Healthz))
	mux.Handle("GET /readyz", http.HandlerFunc(health.Ready))
	mux.Handle("GET /version", http.HandlerFunc(health.Version))

	sessions := &handler.SessionHandler{Store: sessionStore, Logger: logger, BaseURL: cfg.BaseURL, AdminToken: cfg.AdminToken}
	mux.Handle("GET /metrics", http.HandlerFunc(sessions.MetricsHandler))
	mux.Handle("GET /sessions", http.HandlerFunc(sessions.List))
	mux.Handle("POST /sessions", http.HandlerFunc(sessions.Create))
	mux.Handle("GET /sessions/{id}", http.HandlerFunc(sessions.Get))
	mux.Handle("GET /sessions/{id}/watch", http.HandlerFunc(sessions.Watch))
	mux.Handle("PUT /sessions/{id}", http.HandlerFunc(sessions.Put))
	mux.Handle("PATCH /sessions/{id}", http.HandlerFunc(sessions.Patch))
	mux.Handle("DELETE /sessions/{id}", http.HandlerFunc(sessions.Delete))
	mux.Handle("POST /sessions/{id}/lock", http.HandlerFunc(sessions.Lock))
	// Granular live v2 (clean break) — row-level OCC, tanpa snapshot full
	mux.Handle("GET /sessions/{id}/games/{gameKey}", http.HandlerFunc(sessions.GetGame))
	mux.Handle("PATCH /sessions/{id}/games/{gameKey}", http.HandlerFunc(sessions.PatchGame))
	mux.Handle("PATCH /sessions/{id}/absent", http.HandlerFunc(sessions.PatchAbsent))
	mux.Handle("POST /sessions/{id}/swap", http.HandlerFunc(sessions.SwapMembers))
	mux.Handle("GET /sessions/{id}/events", http.HandlerFunc(sessions.ListEvents))
	// Unlock = operasi admin (ADMIN_MENU_PLAN.md §3.1) — di-gate.
	mux.Handle("POST /sessions/{id}/unlock", handler.AdminGuard(cfg.AdminToken, sessions.Unlock))
	// Delete admin: sesi status apa pun (locked termasuk) + bersihkan rating source.
	mux.Handle("POST /sessions/{id}/delete", handler.AdminGuard(cfg.AdminToken, sessions.DeleteAdmin))

	players := &handler.PlayerHandler{
		Store:      store.NewPlayerStore(pool),
		Logger:     logger,
		AdminToken: cfg.AdminToken,
		AdminStore: store.NewSessionStore(pool, cfg.DatabaseSchema),
	}
	mux.Handle("PATCH /players/{playerId}/tier", handler.AdminGuard(cfg.AdminToken, players.SetTier))
	mux.Handle("PATCH /players/{playerId}/name", handler.AdminGuard(cfg.AdminToken, players.Rename))
	mux.Handle("DELETE /players/{playerId}", handler.AdminGuard(cfg.AdminToken, players.Delete))
	mux.Handle("POST /players/merge", handler.AdminGuard(cfg.AdminToken, players.Merge))
	mux.Handle("GET /players", http.HandlerFunc(players.List))
	mux.Handle("POST /players", http.HandlerFunc(players.Register))
	mux.Handle("GET /players/{name}/stats", http.HandlerFunc(players.Stats))

	tournaments := &handler.TournamentHandler{Store: store.NewTournamentStore(pool, cfg.DatabaseSchema), Logger: logger, BaseURL: cfg.BaseURL, AdminStore: store.NewSessionStore(pool, cfg.DatabaseSchema)}
	mux.Handle("GET /tournaments", http.HandlerFunc(tournaments.List))
	mux.Handle("POST /tournaments", http.HandlerFunc(tournaments.Create))
	mux.Handle("GET /tournaments/{id}", http.HandlerFunc(tournaments.Get))
	mux.Handle("PUT /tournaments/{id}", http.HandlerFunc(tournaments.Put))
	mux.Handle("PATCH /tournaments/{id}", http.HandlerFunc(tournaments.Patch))
	// Delete admin: tournament status apa pun + bersihkan rating source.
	mux.Handle("POST /tournaments/{id}/delete", handler.AdminGuard(cfg.AdminToken, tournaments.DeleteAdmin))

	// ── Rating engine (design §6): write = admin token, read = publik.
	ratings := &handler.RatingsHandler{
		Store:      store.NewSessionStore(pool, cfg.DatabaseSchema),
		AdminToken: cfg.AdminToken,
	}
	mux.Handle("POST /ratings/ingest-session", http.HandlerFunc(ratings.RequireAdmin(ratings.IngestSession)))
	mux.Handle("POST /ratings/ingest-tournament", http.HandlerFunc(ratings.RequireAdmin(ratings.IngestTournament)))
	mux.Handle("POST /ratings/revert-session", http.HandlerFunc(ratings.RequireAdmin(ratings.RevertSession)))
	mux.Handle("POST /ratings/revert-tournament", http.HandlerFunc(ratings.RequireAdmin(ratings.RevertTournament)))
	mux.Handle("POST /ratings/sources/{sourceId}/finalize", http.HandlerFunc(ratings.RequireAdmin(ratings.FinalizeSource)))
	mux.Handle("POST /ratings/rebuild-all", http.HandlerFunc(ratings.RequireAdmin(ratings.RebuildAll)))
	mux.Handle("POST /ratings/season", http.HandlerFunc(ratings.RequireAdmin(ratings.Season)))
	mux.Handle("POST /ratings/players/{playerId}/rebaseline", http.HandlerFunc(ratings.RequireAdmin(ratings.Rebaseline)))
	// Read path (publik)
	mux.Handle("GET /ratings/leaderboard", http.HandlerFunc(ratings.Leaderboard))
	mux.Handle("GET /ratings/players/{playerId}", http.HandlerFunc(ratings.Player))
	mux.Handle("GET /ratings/sources", http.HandlerFunc(ratings.Sources))
	mux.Handle("GET /ratings/seasons", http.HandlerFunc(ratings.Seasons))
	mux.Handle("GET /ratings/seasons/{seasonId}/standings", http.HandlerFunc(ratings.SeasonStandings))

	// Middleware chain: recover (luar) → request-id → logging → CORS → rate limit → mux.
	var h http.Handler = mux
	h = middleware.RateLimit(ctx, cfg.RateLimitPerMin, logger)(h)
	h = middleware.CORS(cfg.AllowedOrigins)(h)
	h = middleware.Logging(logger)(h)
	h = middleware.RequestID(h)
	h = middleware.Recover(logger)(h)
	return h
}

// parseLogLevel — map MAJADU_LOG_LEVEL ("debug"/"info"/"warn") ke slog.Level.
// Nilai tidak dikenal → default Info.
func parseLogLevel(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
