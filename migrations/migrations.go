// Package migrations embeds the goose SQL migrations so the server binary can
// migrate without a goose CLI. The same files are sqlc's schema source.
package migrations

import (
	"context"
	"database/sql"
	"embed"

	"github.com/pressly/goose/v3"
)

//go:embed *.sql
var FS embed.FS

// Up applies all pending migrations.
func Up(ctx context.Context, db *sql.DB) ([]*goose.MigrationResult, error) {
	p, err := goose.NewProvider(goose.DialectPostgres, db, FS)
	if err != nil {
		return nil, err
	}
	return p.Up(ctx)
}
