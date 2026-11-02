# Group Balance – design system

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
  buttons.
- **Group switcher** is the navigation title menu (`toolbarTitleMenu`).
- **Lists** are `List` / `Form` with `.insetGrouped` style; sections with
  headers and footers instead of custom labels, cards or hairlines.
- **Sheets** for self-contained tasks (new payment, record arrival, invite,
  join, create group). Cancel leading, the action trailing.
- **Overview** shows your balance (with the expected balance once pending
  money arrives), money waiting for arrival, balances, and the 5 latest
  payments with a `Show all` row (badge = count) that pushes the full,
  searchable list. Who pays whom is not on it.
- **Settle up** is its own tab with one plan: who pays whom once every
  pending payment has arrived (PROTOCOL.md §9.4), so nothing is paid that a
  pending payment would send back. Each transfer shows what is due now
  (§9.5): nothing extra when all of it can be paid, "X now, Y once the money
  arrives", or "once the money on its way arrives". Your payments carry a
  trailing capsule `Pay X` button (`.bordered`, `.capsule`) for the amount
  due now; a recorded but unconfirmed settlement shows "sent, waiting for
  confirmation". A notice at the top explains when the plan counts money
  still on its way; the pending payments are listed under Still expected.
- **Multi-step tasks** push steps in the sheet's `NavigationStack`: the back
  button and swipe-back work, the trailing button says `Next` until the last
  step, which says `Save`.

## Color

Restrained: system backgrounds and labels, plus

| Role | Value | Use |
|---|---|---|
| Tint | `Color.indigo` (system, adapts) | every interactive element, selection |
| Positive | `Color.green` (system) | money owed to someone, arrived |
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
