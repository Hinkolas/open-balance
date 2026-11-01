-- +goose Up
-- The server stores no content: groups, the public keys allowed to use them
-- and the encrypted event log (docs/PROTOCOL.md §5).

CREATE TABLE groups (
    id            uuid        PRIMARY KEY,
    head_seq      bigint      NOT NULL DEFAULT 0,
    bytes_used    bigint      NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_write_at timestamptz
);

CREATE TABLE group_keys (
    group_id   uuid        NOT NULL REFERENCES groups (id) ON DELETE CASCADE,
    public_key bytea       NOT NULL CHECK (length(public_key) = 32),
    role       text        NOT NULL CHECK (role IN ('admin', 'member', 'invite')),
    status     text        NOT NULL CHECK (status IN ('active', 'pending', 'claimed', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, public_key)
);

CREATE TABLE events (
    group_id    uuid        NOT NULL REFERENCES groups (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    id          uuid        NOT NULL,
    blob        bytea       NOT NULL,
    author_key  bytea       NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, seq),
    UNIQUE (group_id, id)
);

-- +goose Down
DROP TABLE events;
DROP TABLE group_keys;
DROP TABLE groups;
