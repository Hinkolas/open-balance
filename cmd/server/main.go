// Command server is the Group Balance server: a headless JSON API that keeps
// the encrypted ledgers of groups (docs/PROTOCOL.md).
//
//	server [serve]           run the API
//	server migrate           apply database migrations
//	server vectors <dir>     write spec/vectors/crypto.json
//
// Environment: DATABASE_URL (required for serve and migrate), PORT (8080),
// ADMIN_TOKEN (server owner; empty disables group creation), SERVER_NAME,
// MAX_GROUP_EVENTS (100000), MAX_GROUP_BYTES (268435456), APPENDS_PER_MINUTE (600).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/KiloHertz-IT/group-balance/internal/api"
	"github.com/KiloHertz-IT/group-balance/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
)

var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch cmd {
	case "serve":
		err = serve(ctx)
	case "migrate":
		err = migrate(ctx)
	case "vectors":
		if len(os.Args) < 3 {
			err = errors.New("usage: server vectors <dir>")
		} else {
			err = writeVectors(os.Args[2])
		}
	default:
		err = fmt.Errorf("unknown command %q (serve, migrate, vectors)", cmd)
	}
	if err != nil {
		slog.Error("fatal", "cmd", cmd, "err", err)
		os.Exit(1)
	}
}

func openPool(ctx context.Context) (*pgxpool.Pool, error) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		return nil, errors.New("DATABASE_URL is required")
	}
	return pgxpool.New(ctx, url)
}

func migrate(ctx context.Context) error {
	pool, err := openPool(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	res, err := migrations.Up(ctx, db)
	for _, r := range res {
		slog.Info("migrated", "version", r.Source.Version, "file", r.Source.Path)
	}
	return err
}

func serve(ctx context.Context) error {
	pool, err := openPool(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()

	cfg := api.Config{
		Name:           envOr("SERVER_NAME", "Group Balance"),
		Version:        version,
		AdminToken:     os.Getenv("ADMIN_TOKEN"),
		MaxGroupEvents: envInt("MAX_GROUP_EVENTS", 100_000),
		MaxGroupBytes:  envInt("MAX_GROUP_BYTES", 256<<20),
		AppendsPerMin:  int(envInt("APPENDS_PER_MINUTE", 600)),
	}
	if cfg.AdminToken == "" {
		slog.Warn("ADMIN_TOKEN is empty: group creation is disabled")
	} else if len(cfg.AdminToken) < 32 {
		slog.Warn("ADMIN_TOKEN is shorter than 32 characters")
	}

	hub := api.NewHub()
	go hub.Listen(ctx, pool)

	srv := &http.Server{
		Addr:              ":" + envOr("PORT", "8080"),
		Handler:           api.New(cfg, pool, hub).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// Streams end on SIGTERM instead of holding up the shutdown; clients
		// reconnect and appends are idempotent.
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	errc := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", srv.Addr, "version", version)
		errc <- srv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

func envOr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func envInt(name string, def int64) int64 {
	if v, err := strconv.ParseInt(os.Getenv(name), 10, 64); err == nil {
		return v
	}
	return def
}
