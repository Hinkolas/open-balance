# Open Balance – plan

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
| Crypto | HKDF-SHA256, ChaCha20-Poly1305, Ed25519, SHA-256. CryptoKit on iOS, BouncyCastle (lightweight API) on Android, stdlib + x/crypto in Go | Available on every target platform; BouncyCastle behaves the same on every Android version |
| Identity | One Ed25519 key per device of a member per group; a member (a person or a company) may have several, all equal. Signs events (clients verify) and requests (server verifies). No accounts | A member is identified by its keys; tracking is per member, not per person |
| Joining | Per-member invite: admin adds and names the member, shows that member's QR (server, group id, member id, group secret, one-time invite key) for its first device. Further devices: any device of the member shows a one-time device QR for its own member (2026-11-01) | One invite, one key; the admin can't add devices to a member that already joined, so nobody else can speak for it |
| Permissions | Server: who may read and write (key registry, roles). Clients: content rules, enforced identically, invalid events stay visible | The server can't see content |
| Content rules | Any member records payments for anyone. Only the receiver (any member for unclaimed seats) or the admin records an arrival. Only the creator or the admin edits or deletes a payment | |
| Payments | One event type with in split, out split, `track` flag. Income, Expense and Settle up are forms over it | One math rule on every platform; new forms need no protocol change |
| Balances | Net per member, debt simplification (greedy, deterministic) | |
| Money | Integer minor units, one currency per group, set at creation | |
| Key storage | iOS: iCloud Keychain (end-to-end encrypted by Apple, synced across the person's devices). Android: files sealed with an Android Keystore AES-GCM key, not backed up (2026-11-02) | iOS survives losing a phone; on Android a lost phone needs a device invite from another device of the member |
| Clients | Native per platform, rewritten against `spec/vectors`. iOS: SwiftUI, iOS 26+, Swift 6. Android: Jetpack Compose, Material 3, Kotlin, Android 11+ (2026-11-02). Windows later | |
| Language | German and English (String Catalogs), informal "du" in German | |
| Design | Quitt's visual language (`docs/DESIGN.md`) | |
| Name | Open Balance, slug `open-balance`, URL scheme `openbalance://`. Under the icon on the home screen: Balance (iOS and Android); stores list Open Balance | |

## Repository layout

```
cmd/server/            serve | migrate | vectors
internal/
  api/                 handlers, request auth, SSE
  store/               sqlc output
  protocol/            envelope, signatures, request signing (Go reference, used by tests and vectors)
migrations/  query/  sqlc.yaml  skali.yaml  Dockerfile  go.mod
apps/apple/
  OpenBalance.xcodeproj
  OpenBalance/        app target: shell, views, localization
  Packages/
    LedgerCore/        crypto, envelope, events, reducer, balances. Pure Swift
    LedgerSync/        API client, outbox, local store, SSE
    Design/            tokens and components (port of QuittDesign)
apps/android/
  ledger-core/         = LedgerCore in Kotlin, pure JVM, runs spec/vectors
  ledger-sync/         = LedgerSync in Kotlin (OkHttp, coroutines), pure JVM
  app/                 Compose app: model, design, ui
apps/windows/          later
spec/vectors/          JSON test vectors, the cross-platform contract
docs/
```

## Server data model

```sql
groups      (id uuid pk, head_seq bigint, bytes_used bigint, created_at, last_write_at)
group_keys  (group_id, public_key bytea, role admin|member|invite,
             status active|pending|claimed|revoked, created_by bytea, grant_role,
             created_at, updated_at, pk (group_id, public_key))
events      (group_id, seq bigint, id uuid, blob bytea, author_key bytea, received_at,
             pk (group_id, seq), unique (group_id, id))
```

Append: one transaction, `UPDATE groups SET head_seq = head_seq + n … RETURNING`
(serializes appends per group), insert events, `NOTIFY` for the SSE fan-out
across replicas.

## iOS app

Tabs: **Overview** (your balance, expected arrivals, balances, payments),
**Settle up** (who pays whom once everything arrives, and what can be paid
now), **History** (the ledger timeline), **Group** (members, devices,
servers), and a separate **+**.

- **+**: Income, Expense, Settle up. Each form asks only what it needs and
  writes the same payment event; an "Advanced" toggle shows both splits.
- **Payment detail**: lines, arrivals ("record arrival", instalments),
  edit, delete, edit history.
- **Members** (admin): add member → name → QR. Renew a lost invite.
- **Devices** (everyone, own member): add a device → one-time QR, revocable.
- **Join**: camera scanner or paste a link → claim → "Welcome, Anna".
- **Servers**: add a server as owner (URL + admin token) to create groups.
- Offline-first: writes go to an outbox with client ids and apply
  optimistically; the ledger cache is local (SQLite via GRDB); state is
  rebuilt in memory.
- Showing an invite or device QR asks for Face ID, Touch ID or the passcode
  first (it hands out the group secret). App lock is the system's own
  "Require Face ID" (iOS 18+); the group settings point to it. (2026-11-02)

## Android app (2026-11-02)

The iOS app's structure and flows, in Android's idiom (docs/DESIGN.md,
Android): a navigation bar for the four sections, a floating + button,
full-screen task screens instead of sheets, bottom sheets for small tasks.

- Kotlin modules mirror the Swift packages one to one and pass the same
  vectors and the ported ledger and integration tests.
- Event bodies decode exactly like Swift's `JSONDecoder` (no quoted
  numbers, required fields typed), and lenient spots of the Swift client
  are matched on purpose (base64url also takes `+` and `/`; dates accept a
  leading `+` per part) so both clients reject the same events. Better: pin
  these in `ledger.json` and tighten both.
- QR: generated and scanned with ZXing (CameraX preview), no Google Play
  services. Invite links also open from the system camera app
  (`openbalance://join` intent filter).
- Showing an invite or device QR asks for the fingerprint, face or screen
  lock (BiometricPrompt), like Face ID on iOS.
- Release builds allow HTTPS only; debug builds also plain HTTP.


0. **Spec**: `docs/PROTOCOL.md`, math vectors (`spec/vectors/balances.json`,
   `transfers.json`). Repo, README, CLAUDE.md. ✓ 2026-11-01
1. **Go protocol + vectors**: `internal/protocol` (envelope, signatures,
   chain, request signing), `cmd/server vectors` generates `crypto.json`. ✓ 2026-11-01
   Open: `ledger.json` (signed event sequences → state and rejections); the
   reducer rules are covered by Swift tests for now.
2. **Server**: migrations, sqlc queries, endpoints, request auth, quotas, SSE
   via LISTEN/NOTIFY, owner endpoints, Dockerfile, `skali.yaml`, tests
   against Postgres. ✓ 2026-11-01 (not deployed yet)
3. **LedgerCore** (Swift): crypto, envelope, reducer, balances, transfers. All
   vectors green. ✓ 2026-11-01
4. **LedgerSync** (Swift): client, request signing, outbox, local cache (JSON
   files for now, GRDB if ledgers grow), SSE, integration test against a
   local server. ✓ 2026-11-01
5. **iOS UI**: Design package, shell, create group, add member + QR, join,
   overview, payment forms, payment detail with arrivals, history,
   German + English. First version ✓ 2026-11-01, not yet run in a simulator.
6. **Android**: ledger-core, ledger-sync, Compose app; vectors, ledger and
   integration tests green; interop with the Swift client checked against a
   local server. ✓ 2026-11-02
7. **Release**: App Store and Play Store assets, privacy copy (what the server sees),
   deploy to skali at the production domain.

## Roadmap

- Remove members: `member.removed`, server key status `removed`, key epochs
  (`K_enc` rotation).
- Several admins; let the server owner hand out one-time group creation codes.
- Encrypted snapshots for long ledgers; encrypted attachments (receipt photos)
  in a bucket.
- Push notifications ("group changed", no content) via APNs.
- Windows (and macOS via the Apple target).
- Android: synced key backup (Google Block Store, end-to-end encrypted)
  so a lost phone doesn't need a device invite.
- Payment handoff from Quitt: IBAN / PayPal.me inside the encrypted ledger,
  EPC QR on Settle up.

## Open points

- Production domain on skali for the reference server.
