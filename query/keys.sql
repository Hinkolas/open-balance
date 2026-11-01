-- name: InsertKey :execrows
INSERT INTO group_keys (group_id, public_key, role, status) VALUES ($1, $2, $3, $4)
ON CONFLICT DO NOTHING;

-- name: GetKey :one
SELECT role, status FROM group_keys WHERE group_id = $1 AND public_key = $2;

-- name: SetInviteStatus :execrows
UPDATE group_keys SET status = sqlc.arg(new_status), updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role = 'invite' AND status = 'pending';
