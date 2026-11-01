-- name: GetEventSeq :one
SELECT seq FROM events WHERE group_id = $1 AND id = $2;

-- name: InsertEvent :exec
INSERT INTO events (group_id, seq, id, blob, author_key) VALUES ($1, $2, $3, $4, $5);

-- name: ListEvents :many
SELECT seq, id, blob, author_key, received_at FROM events
WHERE group_id = $1 AND seq > $2 ORDER BY seq LIMIT $3;
