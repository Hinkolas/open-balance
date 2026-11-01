-- name: CreateGroup :execrows
INSERT INTO groups (id) VALUES ($1) ON CONFLICT DO NOTHING;

-- name: LockGroup :one
SELECT head_seq, bytes_used FROM groups WHERE id = $1 FOR UPDATE;

-- name: GetHead :one
SELECT head_seq FROM groups WHERE id = $1;

-- name: AdvanceHead :exec
UPDATE groups SET head_seq = $2, bytes_used = $3, last_write_at = now() WHERE id = $1;

-- name: ListGroups :many
SELECT id, head_seq, bytes_used, created_at, last_write_at FROM groups ORDER BY created_at;

-- name: DeleteGroup :execrows
DELETE FROM groups WHERE id = $1;
