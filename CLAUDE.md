# Group Balance

Read `docs/PLAN.md` (decisions, phases), then `docs/PROTOCOL.md` (the
normative contract), then `docs/DESIGN.md`.

## Rules
- The server never sees content. Anything about payments, members' names or
  amounts lives inside encrypted events; the server stores blobs, seq and keys.
- `docs/PROTOCOL.md` + `spec/vectors/*.json` are the contract. Change them
  first, then the Go reference and the clients. All implementations must pass
  every vector.
- Money is integer minor units everywhere, never floating point. Products in
  the balance math need 128-bit intermediates.
- Ordering is the server `seq` only. Never order by client timestamps.
- Invalid events change no state but stay visible in the history with a reason.
- Payments are one event type; Income, Expense and Settle up are forms.
- UI is native iOS (docs/DESIGN.md): system lists, controls, text styles and
  colors; `Theme.tint/positive/negative` and the components in the `Design`
  package for the brand layer. No hex colors or fixed font sizes in views.
- Product context for design work lives in `PRODUCT.md`.
- UI copy in German and English (String Catalogs), German with informal "du".
- `ADMIN_TOKEN`, group secrets and private keys never appear in logs.

## Commands
See README.md "Development". Swift packages test with `swift test` in their
directory; the app builds with
`xcodebuild -project apps/apple/GroupBalance.xcodeproj -scheme GroupBalance -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build`.
UI strings: English keys in code, German in `apps/apple/GroupBalance/Localizable.xcstrings`.
After editing the catalog by hand, let Xcode normalize it so builds in Xcode
don't rewrite it:
`xcodebuild -exportLocalizations -project apps/apple/GroupBalance.xcodeproj -localizationPath /tmp/gb-l10n -exportLanguage de -skipPackagePluginValidation`.
Strings used only in Swift packages (e.g. `FlowError`) are `"extractionState" : "manual"`.
