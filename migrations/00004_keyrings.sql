-- +goose Up
-- Key epochs (docs/PROTOCOL.md §3.5, §6.1): blobs are version 2 and invites
-- and recovery keys carry a keyring sealed to their box key. Earlier groups
-- can't be read by current clients, so they are dropped.
DELETE FROM groups;

ALTER TABLE group_keys ADD COLUMN keyring bytea CHECK (keyring IS NULL OR length(keyring) <= 65536);

-- +goose Down
ALTER TABLE group_keys DROP COLUMN keyring;
