-- +goose Up
-- Seats, removed keys, recovery keys and creation codes (docs/PROTOCOL.md §5.2, §5.3).
-- Groups created before this have no recovery key and no seats; they are not
-- supported any more, so they are dropped.
DELETE FROM groups;

ALTER TABLE group_keys
    DROP CONSTRAINT group_keys_role_check,
    DROP CONSTRAINT group_keys_status_check,
    ADD CONSTRAINT group_keys_role_check CHECK (role IN ('admin', 'member', 'recovery', 'invite')),
    ADD CONSTRAINT group_keys_status_check CHECK (status IN ('active', 'pending', 'claimed', 'revoked', 'removed')),
    ADD COLUMN seat bytea CHECK (seat IS NULL OR length(seat) = 32);

CREATE INDEX group_keys_seat ON group_keys (group_id, seat);
CREATE INDEX group_keys_created_by ON group_keys (group_id, created_by);

-- One-time codes the server owner hands out so someone else can create a
-- group. Only the SHA-256 of a code is stored.
CREATE TABLE creation_codes (
    id         uuid        PRIMARY KEY,
    code_hash  bytea       NOT NULL UNIQUE CHECK (length(code_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz,
    group_id   uuid
);

-- +goose Down
DROP TABLE creation_codes;
DROP INDEX group_keys_created_by;
DROP INDEX group_keys_seat;
ALTER TABLE group_keys
    DROP COLUMN seat,
    DROP CONSTRAINT group_keys_role_check,
    DROP CONSTRAINT group_keys_status_check,
    ADD CONSTRAINT group_keys_role_check CHECK (role IN ('admin', 'member', 'invite')),
    ADD CONSTRAINT group_keys_status_check CHECK (status IN ('active', 'pending', 'claimed', 'revoked'));
