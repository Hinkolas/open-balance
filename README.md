# Open Balance

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

Local runs use [skali](https://github.com/Hinkolas/skali) (`skali.yaml`):
`skali dev` starts Postgres on the local skali platform and the Go server on
this Mac, which migrates and then serves at `https://open-balance.localhost`
(the platform's development CA; `skali dev` trusts it on the Mac).

```sh
cp .env.example .env                       # set ADMIN_TOKEN: openssl rand -base64 32
skali dev --env-file .env                  # Ctrl-C pauses, data stays
curl https://open-balance.localhost/v1/info

# tests (with skali dev running)
skali dev run test                         # Go, against the dev database
(cd apps/apple/Packages/LedgerCore && swift test)
(cd apps/apple/Packages/LedgerSync && OB_TEST_SERVER=https://open-balance.localhost \
  OB_TEST_OWNER_TOKEN=$(grep ^ADMIN_TOKEN= ../../../../.env | cut -d= -f2-) swift test)

# database shell, other commands
skali dev sql data
skali dev run migrate

# regenerate crypto vectors after a protocol change
go run ./cmd/server vectors spec/vectors

# iOS app
open apps/apple/OpenBalance.xcodeproj
```

The iOS Simulator has its own trust store. Add the development CA once per
simulator (it changes only after `skali dev reset`). Older dev CAs may still
be in your keychain, so pick the one that signed the running server's
certificate (`skali dev` must be running):

```sh
CA=$(echo | openssl s_client -connect 127.0.0.1:443 -servername open-balance.localhost 2>/dev/null \
  | openssl x509 -noout -issuer -nameopt multiline | sed -n 's/^ *commonName *= //p')
security find-certificate -c "$CA" -p ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain > /tmp/skali-dev-ca.pem
xcrun simctl keychain booted add-root-cert /tmp/skali-dev-ca.pem
```

In the app: **Create a group → Add server** with
`https://open-balance.localhost` and the `ADMIN_TOKEN` from `.env`. Then add
a member and copy the invite link; on a second simulator or device, **Join
with an invite** and paste it.

## Staging

`https://group-balance.staging.khz.dev` on the `khz` skali cluster, with
values from `.env.staging` (git-ignored; same keys as `.env.example`, its
own `ADMIN_TOKEN`).

```sh
skali plan --environment staging --env-file .env.staging
skali deploy --environment staging --env-file .env.staging
skali logs --environment staging
```

The deploy builds the `Dockerfile`, runs `/server migrate` as the release
command and waits for health and the TLS certificate.

## Run on your iPhone

Needs Xcode 26 or later, an iPhone on iOS 26+, and an Apple ID signed in
under Xcode → Settings → Accounts (a paid developer team, or a free personal
team whose builds expire after 7 days).

```sh
git clone https://github.com/Hinkolas/open-balance.git
cd open-balance
cp apps/apple/Signing.local.xcconfig.example apps/apple/Signing.local.xcconfig
# set DEVELOPMENT_TEAM; with a free team also set your own PRODUCT_BUNDLE_IDENTIFIER
open apps/apple/OpenBalance.xcodeproj
```

1. Connect the iPhone (cable once; then it also works over Wi-Fi), trust the
   Mac, and turn on Settings → Privacy & Security → Developer Mode.
2. In Xcode pick the iPhone as run destination and press Run (⌘R). Xcode
   creates the provisioning profile itself (automatic signing).
3. With a free team, trust the developer once on the phone: Settings →
   General → VPN & Device Management.

**Server.** The phone can't reach `open-balance.localhost`. Use staging,
`https://group-balance.staging.khz.dev`, with the `ADMIN_TOKEN` from
`.env.staging`.
