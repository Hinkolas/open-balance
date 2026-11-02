-- name: InsertCreationCode :one
INSERT INTO creation_codes (id, code_hash, expires_at) VALUES ($1, $2, $3)
RETURNING created_at;

-- name: UseCreationCode :execrows
-- Uses up an unused, unexpired code for the group it creates.
UPDATE creation_codes SET used_at = now(), group_id = sqlc.arg(group_id)
WHERE code_hash = sqlc.arg(code_hash) AND used_at IS NULL AND expires_at > now();

-- name: ListCreationCodes :many
SELECT id, created_at, expires_at, used_at, group_id FROM creation_codes ORDER BY created_at;

-- name: DeleteCreationCode :execrows
DELETE FROM creation_codes WHERE id = $1 AND used_at IS NULL;
