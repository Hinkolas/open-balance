# Group Balance

Track money in a group: who received what, whom it belongs to, how much has
arrived, and in the end who pays whom. End-to-end encrypted: the server keeps
an ordered log of ciphertext and never sees names or amounts. Bring your own
server.

```
cmd/server/       Go server (headless JSON API): serve | migrate
internal/         api, store (sqlc), protocol
migrations/       Postgres schema
apps/apple/       SwiftUI app (iOS 26+) and its Swift packages
apps/android/     later
apps/windows/     later
spec/vectors/     test vectors every implementation must pass
docs/             plan, protocol, design
```

Start with `docs/PLAN.md`, then `docs/PROTOCOL.md`.
