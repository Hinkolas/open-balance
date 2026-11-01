# Group Balance – plan

Status: 2026-11-01. Protocol: `docs/PROTOCOL.md`. Design: `docs/DESIGN.md`.

## Product in one paragraph

A group of people tracks money that moves through it. Every payment has two
knobs: **in**, who received the money (or value), and **out**, whom it
belongs to. For money that has to arrive first (a client paying an invoice, a
friend paying someone back), members record how much actually arrived and
only that counts. From all payments the app derives one **net balance** per
member and a short **who pays whom** list (A owes B and B owes C becomes A
pays C). Everything is end-to-end encrypted: the server stores an ordered log
of ciphertext and never sees names or amounts.

## Decisions

| Area | Decision | Why |
|---|---|---|
| Data | Append-only encrypted event ledger per group; clients replay it into state | Server never sees content; history is reproducible from the ledger |
| Server | Go, net/http, sqlc + pgx/v5, Postgres 17, headless JSON API, hosted on skali | |
| Hosting model | Bring your own server. Only the server owner (`ADMIN_TOKEN`) creates groups | |
| Crypto | HKDF-SHA256, ChaCha20-Poly1305, Ed25519, SHA-256. CryptoKit on iOS, stdlib + x/crypto in Go | Available natively on every target platform |
| Identity | One Ed25519 member key per member per group. Signs events (clients verify) and requests (server verifies). No accounts | A member is identified by their key |
| Joining | Per-member invite only: admin adds and names the member, shows that member's QR (server, group id, member id, group secret, one-time invite key) | One seat, one key; makes removal possible later |
| Permissions | Server: who may read and write (key registry, roles). Clients: content rules, enforced identically, invalid events stay visible | The server can't see content |
| Content rules | Any member records payments for anyone. Only the receiver (any member for unclaimed seats) or the admin records an arrival. Only the creator or the admin edits or deletes a payment | |
| Payments | One event type with in split, out split, `track` flag. Income, Expense and Settle up are forms over it | One math rule on every platform; new forms need no protocol change |
| Balances | Net per member, debt simplification (greedy, deterministic) | |
| Money | Integer minor units, one currency per group, set at creation | |
| Key storage | iCloud Keychain (end-to-end encrypted by Apple, synced across the person's devices) | Survives losing a phone |
| Clients | Native per platform. iOS first: SwiftUI, iOS 26+, Swift 6. Android and Windows later, rewritten against `spec/vectors` | |
| Language | German and English (String Catalogs), informal "du" in German | |
| Design | Quitt's visual language (`docs/DESIGN.md`) | |
| Name | Group Balance, slug `group-balance`, URL scheme `groupbalance://` | |

## Repository layout

```
cmd/server/            serve | migrate | vectors
internal/
  api/                 handlers, request auth, SSE
  store/               sqlc output
  protocol/            envelope, signatures, request signing (Go reference, used by tests and vectors)
migrations/  query/  sqlc.yaml  skali.yaml  Dockerfile  go.mod
apps/apple/
  GroupBalance.xcodeproj
  GroupBalance/        app target: shell, views, localization
  Packages/
    LedgerCore/        crypto, envelope, events, reducer, balances. Pure Swift
    LedgerSync/        API client, outbox, local store, SSE
    Design/            tokens and components (port of QuittDesign)
apps/android/  apps/windows/   later
spec/vectors/          JSON test vectors, the cross-platform contract
docs/
```

## Server data model

```sql
groups      (id uuid pk, head_seq bigint, bytes_used bigint, created_at, last_write_at)
group_keys  (group_id, public_key bytea, role admin|member|invite,
             status active|pending|claimed|revoked, created_at, claimed_at,
             pk (group_id, public_key))
events      (group_id, seq bigint, id uuid, blob bytea, author_key bytea, received_at,
             pk (group_id, seq), unique (group_id, id))
```

Append: one transaction, `UPDATE groups SET head_seq = head_seq + n … RETURNING`
(serializes appends per group), insert events, `NOTIFY` for the SSE fan-out
across replicas.

## iOS app

Tabs as in Quitt: **Overview** (your balance, who pays whom, expected
arrivals), **History** (the ledger timeline), **Account** (groups, servers,
members), and a separate **+**.

- **+**: Income, Expense, Settle up. Each form asks only what it needs and
  writes the same payment event; an "Advanced" toggle shows both splits.
- **Payment detail**: lines, arrivals ("record arrival", instalments),
  edit, delete, edit history.
- **Members** (admin): add member → name → QR. Renew a lost invite.
- **Join**: camera scanner or paste a link → claim → "Welcome, Anna".
- **Servers**: add a server as owner (URL + admin token) to create groups.
- Offline-first: writes go to an outbox with client ids and apply
  optimistically; the ledger cache is local (SQLite via GRDB); state is
  rebuilt in memory.
- Face ID lock: optional, roadmap.

## Phases

0. **Spec**: `docs/PROTOCOL.md`, math vectors (`spec/vectors/balances.json`,
   `transfers.json`). Repo, README, CLAUDE.md. ✓ 2026-11-01
1. **Go protocol + vectors**: `internal/protocol` (envelope, signatures,
   chain, request signing), `cmd/server vectors` generates `crypto.json` and
   `ledger.json` (signed event sequences → expected state and rejections).
2. **Server**: migrations, sqlc queries, endpoints, request auth, quotas, SSE
   via LISTEN/NOTIFY, owner endpoints, Dockerfile, `skali.yaml`, tests
   against Postgres.
3. **LedgerCore** (Swift): crypto, envelope, reducer, balances, transfers. All
   vectors green.
4. **LedgerSync** (Swift): client, request signing, outbox, local store, SSE,
   integration tests against a local server.
5. **iOS UI**: Design package, shell, create group, add member + QR, join,
   overview, payment forms, payment detail with arrivals, history,
   German + English.
6. **Release**: App Store assets, privacy copy (what the server sees),
   deploy to skali at the production domain.

## Roadmap

- Remove members: `member.removed`, server key status `removed`, key epochs
  (`K_enc` rotation).
- Several admins; let the server owner hand out one-time group creation codes.
- Encrypted snapshots for long ledgers; encrypted attachments (receipt photos)
  in a bucket.
- Push notifications ("group changed", no content) via APNs.
- Face ID lock.
- Android, Windows (and macOS via the Apple target).
- Payment handoff from Quitt: IBAN / PayPal.me inside the encrypted ledger,
  EPC QR on Settle up.

## Open points

- Production domain on skali for the reference server.
