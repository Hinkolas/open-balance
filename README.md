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

## Development

```sh
docker compose up -d                       # Postgres on 127.0.0.1:55441
cp .env.example .env                       # set ADMIN_TOKEN: openssl rand -base64 32
set -a && . ./.env && set +a
go run ./cmd/server migrate
go run ./cmd/server                        # http://localhost:8080/v1/info

# tests
TEST_DATABASE_URL=$DATABASE_URL go test ./...
(cd apps/apple/Packages/LedgerCore && swift test)
(cd apps/apple/Packages/LedgerSync && GB_TEST_SERVER=http://localhost:8080 GB_TEST_OWNER_TOKEN=$ADMIN_TOKEN swift test)

# regenerate crypto vectors after a protocol change
go run ./cmd/server vectors spec/vectors

# iOS app
open apps/apple/GroupBalance.xcodeproj
```

In the app: **Create a group → Add server** with `http://localhost:8080` and
the `ADMIN_TOKEN` from `.env` (the simulator reaches the Mac's localhost).
Then add a member and copy the invite link; on a second simulator or device,
**Join with an invite** and paste it.

## Run on your iPhone

Needs Xcode 26 or later, an iPhone on iOS 26+, and an Apple ID signed in
under Xcode → Settings → Accounts (a paid developer team, or a free personal
team whose builds expire after 7 days).

```sh
git clone https://github.com/KiloHertz-IT/group-balance.git
cd group-balance
cp apps/apple/Signing.local.xcconfig.example apps/apple/Signing.local.xcconfig
# set DEVELOPMENT_TEAM; with a free team also set your own PRODUCT_BUNDLE_IDENTIFIER
open apps/apple/GroupBalance.xcodeproj
```

1. Connect the iPhone (cable once; then it also works over Wi-Fi), trust the
   Mac, and turn on Settings → Privacy & Security → Developer Mode.
2. In Xcode pick the iPhone as run destination and press Run (⌘R). Xcode
   creates the provisioning profile itself (automatic signing).
3. With a free team, trust the developer once on the phone: Settings →
   General → VPN & Device Management.

**Server.** The phone can't reach `localhost`. Either run the server on the
Mac as above and add it in the app as `http://<mac-name>.local:8080` (the
Mac's name from System Settings → General → Sharing → Local hostname; phone
on the same Wi-Fi), or deploy it with `skali.yaml` and use its HTTPS
domain. Plain HTTP only works on the local network.
