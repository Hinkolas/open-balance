-- name: InsertKey :execrows
INSERT INTO group_keys (group_id, public_key, role, status) VALUES ($1, $2, $3, $4)
ON CONFLICT DO NOTHING;

-- name: GetKey :one
SELECT role, status FROM group_keys WHERE group_id = $1 AND public_key = $2;

-- name: InsertInvite :execrows
INSERT INTO group_keys (group_id, public_key, role, status, created_by, grant_role)
VALUES ($1, $2, 'invite', 'pending', sqlc.arg(created_by), sqlc.arg(grant_role))
ON CONFLICT DO NOTHING;

-- name: RevokeInvite :execrows
-- The admin revokes any pending invite, a member only those it created.
UPDATE group_keys SET status = 'revoked', updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role = 'invite' AND status = 'pending'
  AND (sqlc.arg(any_creator)::boolean OR created_by = sqlc.arg(caller));

-- name: ClaimInvite :one
-- Marks a pending invite claimed and returns the role the new key gets.
UPDATE group_keys SET status = 'claimed', updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role = 'invite' AND status = 'pending'
RETURNING grant_role;
