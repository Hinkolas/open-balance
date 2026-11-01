-- +goose Up
-- Invites record the key that created them and the role the claimed key
-- gets, so members can invite further devices of their own (docs/PROTOCOL.md §5.2).
ALTER TABLE group_keys
    ADD COLUMN created_by bytea CHECK (created_by IS NULL OR length(created_by) = 32),
    ADD COLUMN grant_role text CHECK (grant_role IN ('admin', 'member'));
UPDATE group_keys SET grant_role = 'member' WHERE role = 'invite';

-- +goose Down
ALTER TABLE group_keys DROP COLUMN grant_role, DROP COLUMN created_by;
