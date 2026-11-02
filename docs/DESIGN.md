# Open Balance – design system

Status: 2026-11-01. Replaces the ported Quitt look (paper, ink, serif). The
world is **native iOS 26 with a light brand layer**: the platform supplies
layout, navigation and controls; the brand shows in one tint, in how money is
set, and in one signature move. Product truth lives in `PRODUCT.md`.

## Scene

Partners check a group on the phone between meetings or right after a client
paid: daylight and office light as often as evening. Light and Dark Mode are
both first-class and follow the system.

## Structure

- **Tabs** (sections, never actions): Overview, Settle up, History, Group.
  On iPhone Duo and iPad they sit in the side rail.
- **+ is a toolbar button**, top trailing on Overview, Settle up and
  History, a native `Menu` with Income, Expense, Settle up. Liquid Glass
  renders it as the round glass button, like Apple Music's add and more
  buttons. Toolbar icon buttons and their menus are `.tint(.primary)`
  (white in dark mode, like Apple's apps); the tint marks state only, e.g.
  History's filter while a filter is on.
- **Group switcher** is the navigation title menu (`toolbarTitleMenu`).
- **Lists** are `List` / `Form` with `.insetGrouped` style; sections with
  headers and footers instead of custom labels, cards or hairlines.
- **Sheets** for self-contained tasks (new payment, record arrival, invite,
  join, create group). Cancel leading, the action trailing.
- **Overview** shows your balance (with the expected balance once pending
  money arrives), money waiting for arrival, balances, and the 5 most recent
  payments. A `Show all in History` row (badge = count) switches to the
  History tab filtered to payments. Who pays whom is not on it.
- **Settle up** is its own tab with one plan: who pays whom once every
  pending payment has arrived (PROTOCOL.md §9.4), so nothing is paid that a
  pending payment would send back. Each transfer shows what is due now
  (§9.5): nothing extra when all of it can be paid, "X now, Y once the money
  arrives", or "once the money on its way arrives". Your payments carry a
  trailing capsule `Pay X` button (`.bordered`, `.capsule`) for the amount
  due now; a recorded but unconfirmed settlement shows "sent, waiting for
  confirmation". A notice at the top explains when the plan counts money
  still on its way; the pending payments are listed under Still expected.
- **History** groups the ledger by day (Today, Yesterday, then dates) with
  one structured row per event: an `EventIcon` (payment kind symbol or the
  member's initial, both grey so only badges and amounts carry green and
  red) with a small badge only when something changed (edited, deleted, arrived, joined, device, revoked), the payment
  title or member name, "what · by whom" below, and amount and time
  trailing. Each line is one line and truncates instead of wrapping (more at
  accessibility sizes). Settle ups are titled "From → To". Ignored events
  are muted with a red badge and the reason. A filter menu in the toolbar
  (filled icon when active, the filter as navigation subtitle) picks
  Everything, Payments, Arrivals or Members & devices; the search field
  under the title matches titles and details.
- **Multi-step tasks** push steps in the sheet's `NavigationStack`: the back
  button and swipe-back work, the trailing button says `Next` until the last
  step, which says `Save`.

## Color

Restrained: system backgrounds and labels, plus

| Role | Value | Use |
|---|---|---|
| Tint | Emerald (`Theme.tint`; light/dark/high-contrast, matches the app icon) | every interactive element, selection |
| Positive | Same emerald as the tint, so the app has one green | money owed to someone, arrived |
| Negative | `Color.red` (system) | money someone owes, too much |
| Pending | `.secondary` | expected, not arrived yet |

Red and green never carry meaning alone: amounts are signed (`+` / `−`) and
statuses are words.

## Type

System text styles only (Dynamic Type). Money is the one branded voice:

| Role | Style |
|---|---|
| Hero amount (your balance, payment amount) | `.largeTitle`, rounded, semibold, monospaced digits |
| Amount input | `.system(size: 48)` scaled with Dynamic Type via `@ScaledMetric`, rounded, semibold |
| Amount in rows | `.body`, rounded, monospaced digits |
| Everything else | SF Pro text styles (`.body`, `.subheadline`, `.footnote`) |

## Signature move: the balance line

Each member's balance is drawn as a bar diverging from a shared center axis:
owed-to to the right in green, owing to the left in red, scaled to the
largest absolute balance or expected balance in the group. When money is
still on its way, a faint bar (same color, 30 % opacity) behind it marks the
expected balance, with an "Expected ±x" caption so the change never relies on
the bar alone. It appears in Overview's Balances section and nowhere else, so
"who is where, and where they are heading" reads at a glance.

## Components (`Design` package)

- `Amount` – signed, colored, monospaced-digit amount text with an
  accessibility label that speaks the sign.
- `MemberAvatar` – circle with the initial, tint fill for you, secondary fill
  for others.
- `BalanceBar` – the signature move.
- `StatusBadge` – small capsule for "invited", "expected", "arrived",
  "settled", "not synced".

Everything else is a system control: `Button` with `.glassProminent` /
`.glass` / `.borderedProminent` styles, `Picker`, `DatePicker`, `TextField`,
`Menu`, `ProgressView`, `ContentUnavailableView`, swipe actions, context menus.

## Copy voice

English and German (String Catalogs), short, verbs over nouns.

| Concept | German | English |
|---|---|---|
| tone | informal "du" | plain, second person |
| actions | Eintragen, Begleichen, Bestätigen | Add, Settle up, Confirm |
| kinds | Eingang, Ausgabe, Begleichen | Income, Expense, Settle up |
| sides | Wer bekommt das Geld? / Wem gehört es? | Who gets the money? / Whom does it belong to? |
| arrival | angekommen, erwartet | arrived, expected |
| status | quitt, offen | settled, open |

## Android

Status: 2026-11-02. The same product in Android's own idiom: Material 3
supplies layout, navigation and controls; the brand shows in the same three
places (one emerald, money in tabular figures, the balance line). Code:
`apps/android/app/src/main/kotlin/…/design` (`Theme.kt`, `Components.kt`).

| iOS | Android |
|---|---|
| Tab bar: Overview, Settle up, History, Group | `NavigationBar` with the same four sections |
| + toolbar `Menu` | Floating action button with a menu (Income, Expense, Settle up), on the same three tabs |
| Large navigation title | `LargeTopAppBar` that collapses on scroll |
| Group switcher (`toolbarTitleMenu`) | Tap the Overview title (▾) for a menu |
| `.insetGrouped` lists | Grouped sections like Android's Settings: tinted header, rows in one rounded container (`surfaceContainerLow`), footer below |
| Sheets for tasks | Full-screen task screens: close leading, title, action (`Next`, `Save`) trailing; slide up |
| Small sheets (record arrival, rename) | `ModalBottomSheet` |
| Multi-step sheet with `NavigationStack` | Steps in one task screen; back arrow and system back go one step back |
| Swipe actions, context menus | Visible trailing buttons (confirm arrival) and overflow menus (⋮) |
| `confirmationDialog` | `AlertDialog` |
| Pull to refresh | `PullToRefreshBox` |
| Face ID before an invite QR | `BiometricPrompt` (biometrics or screen lock) |

Color: a static Material 3 scheme built around the icon's emerald (no
dynamic color, so the brand stays recognizable). `Brand.tint` and
`Brand.positive` are the scheme's primary, `Brand.negative` its error.
Red and green never carry meaning alone, as on iOS.

Type: Material 3 type scale in `sp` (follows the font size setting). Money
uses `AmountType` (tabular figures; `hero`, `input`, `row`). Android has no
system rounded face, so amounts use the default face. Sizes that should grow
with the font size (avatars, event icons) use `scaled(dp)`.
