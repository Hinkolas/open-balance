# Group Balance – design system

Adopted from the Quitt app. Source of truth for the look:
`design/Quitt – App-Entwurf iOS & Web.pdf` (8 pages, 5 iOS screens, 3 web
screens; gamification and receipt scanning are not part of Group Balance).
This document translates it into tokens. Light is the
primary theme; dark is derived. Never hardcode a color in a view, use `GB.*`
from the `Design` package.

## Principles

- **Paper, ink, two accents.** Warm off-white page, near-black ink, red for
  stamps and debt, green for credit. Nothing else.
- **Serif for headlines, mono for money, sans for everything else.** Headlines
  mix roman and italic ("Fast quitt, *Jonas*."). Every amount, date, counter and
  ratio is monospaced and tabular.
- **Hairlines, not cards.** Sections are separated by 1px lines. The only
  "cards" are the receipt (jagged top/bottom edge) and the dark CTA pill.
- **Section labels** are 11pt uppercase with wide tracking.
- **Numbers right-aligned**, always with the currency symbol after a space.
- **Touch targets ≥ 44pt.** Member chips in the receipt are 36pt squares.
- **Motion** is restrained: `.snappy(duration: 0.2)` for state, stamps animate
  in with a short scale from 0.8.

## Tokens

| Token | Light | Use |
|---|---|---|
| `GB.paper` | #F4F1EA | page background |
| `GB.paperRaised` | #FAF8F3 | receipt, sheets |
| `GB.ink` | #141414 | primary text, dark buttons |
| `GB.ink2` | #5C5A55 | secondary text |
| `GB.ink3` | #8A877F | section labels, meta |
| `GB.hairline` | #D9D4C8 | separators |
| `GB.hairlineStrong` | #141414 | the heavy rule under a page title |
| `GB.red` | #C8371F | stamps, debt, negative amounts |
| `GB.redSoft` | red 10% | stamp fill when done |
| `GB.green` | #2E6B3A | credit, positive amounts, "quitt" badge |
| `GB.greenSoft` | green 10% | |
| `GB.track` | #E3DFD4 | progress track |
| `GB.chipOn` | #141414 | selected member chip |
| `GB.chipOff` | #FAF8F3 + hairline | unselected member chip |

Dark theme: paper → #141311, paperRaised → #1B1A17, ink → #F3F0E8, hairline →
white 10%, red/green lifted by ~10% lightness.

## Type

| Role | Font | Size |
|---|---|---|
| Page title | Instrument Serif, 34pt, italic for the highlighted word | |
| Group title | Instrument Serif, 30pt | |
| Hero amount | IBM Plex Mono SemiBold, 40pt, tabular | |
| Amount in rows | IBM Plex Mono, 15pt, tabular | |
| Body | Inter, 15pt | |
| Secondary | Inter, 13pt, `ink2` | |
| Section label | Inter SemiBold, 11pt, uppercase, tracking 1.2 | |
| Button | Inter SemiBold, 16pt | |

All three fonts are SIL Open Font License. Bundle them in the `Design` package.

## Components (from the PDF)

- **Page header**: eyebrow (date or group meta) + serif title + heavy rule.
- **Summary rows**: label left, mono amount right, hairline between.
- **Group row**: title, progress bar (budget or settlement %), mono amount or
  green "QUITT" tag, chevron.
- **Leaderboard row**: rank, avatar initial, name, horizontal bar, mono amount.
- **Receipt**: jagged edges, serif title, mono meta, line items with member
  chips (A/L/J), summary rows, "Dein Anteil" hero.
- **Settle sheet**: hero amount, EPC QR tile, dark CTA pill.
- **History row**: mono time, verb-first sentence ("Anna hat 84,00 € eingetragen"),
  amount right; days separated by a section label.
- **Status tags**: `GBTag` in green ("quitt", "bestätigt"), red ("offen"), ink3 ("erwartet").
- **Tab bar**: native iOS 26 bar with four tabs (Übersicht, Historie, Konto) and
  a separate "+" (Eintragen).
- **Dark CTA pill**: full-width, 56pt, radius 28, `ink` background, paper text.

## Copy voice

Two languages, German and English, via String Catalogs. Short, verbs over
nouns.

| Concept | German | English |
|---|---|---|
| tone | informal "du" | plain, second person |
| actions | Eintragen, Begleichen, Bestätigen | Add, Settle up, Confirm |
| forms | Eingang, Ausgabe, Begleichen | Income, Expense, Settle up |
| in side / out side | erhalten von / gehört | received by / belongs to |
| arrival | angekommen, erwartet | arrived, expected |
| status | quitt, offen, erhalten, beglichen | settled, open, received, paid |
