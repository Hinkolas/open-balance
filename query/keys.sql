-- name: InsertKey :execrows
INSERT INTO group_keys (group_id, public_key, role, status, seat, keyring) VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT DO NOTHING;

-- name: GetKeyring :one
SELECT keyring FROM group_keys WHERE group_id = $1 AND public_key = $2;

-- name: GetKey :one
SELECT role, status, seat FROM group_keys WHERE group_id = $1 AND public_key = $2;

-- name: InsertInvite :execrows
INSERT INTO group_keys (group_id, public_key, role, status, created_by, grant_role, seat, keyring)
VALUES ($1, $2, 'invite', 'pending', sqlc.arg(created_by), sqlc.arg(grant_role), sqlc.arg(seat), sqlc.arg(keyring))
ON CONFLICT DO NOTHING;

-- name: RevokeInvite :execrows
-- The admin revokes any pending invite, a member only those it created.
UPDATE group_keys SET status = 'revoked', updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role = 'invite' AND status = 'pending'
  AND (sqlc.arg(any_creator)::boolean OR created_by = sqlc.arg(caller));

-- name: ClaimInvite :one
-- Marks a pending invite claimed and returns the role, seat and keyring the new key gets.
UPDATE group_keys SET status = 'claimed', updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role = 'invite' AND status = 'pending'
RETURNING grant_role, seat, keyring;

-- name: RemoveKey :execrows
-- The admin removes any member or admin key, a member only keys of its own seat.
UPDATE group_keys SET status = 'removed', updated_at = now()
WHERE group_id = $1 AND public_key = $2 AND role IN ('admin', 'member') AND status = 'active'
  AND (sqlc.arg(any_seat)::boolean OR seat = sqlc.arg(caller_seat));

-- name: RevokeInvitesCreatedBy :exec
UPDATE group_keys SET status = 'revoked', updated_at = now()
WHERE group_id = $1 AND role = 'invite' AND status = 'pending' AND created_by = sqlc.arg(creator);

-- name: RevokeInvitesOfSeat :exec
-- Pending invites created by any key of the seat.
UPDATE group_keys SET status = 'revoked', updated_at = now()
WHERE group_keys.group_id = $1 AND group_keys.role = 'invite' AND group_keys.status = 'pending'
  AND group_keys.created_by IN (
    SELECT k.public_key FROM group_keys k WHERE k.group_id = $1 AND k.seat = sqlc.arg(seat) AND k.role IN ('admin', 'member'));

-- name: RemoveSeat :exec
UPDATE group_keys SET status = 'removed', updated_at = now()
WHERE group_id = $1 AND seat = sqlc.arg(seat) AND role IN ('admin', 'member') AND status = 'active';

-- name: RemoveRecoveryKeys :exec
UPDATE group_keys SET status = 'removed', updated_at = now()
WHERE group_id = $1 AND role = 'recovery' AND status = 'active';
