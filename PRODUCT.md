# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Primary: business partners — freelancers and small agencies who do projects
together and share the income (e.g. three small studios). A client
pays an invoice, often in instalments, to one or two of them; the money
belongs to the partners in agreed amounts or percentages. They need to record
that quickly, see what has actually arrived, and know who has to pass how much
on to whom. Private groups (trips, flat shares, dinners) work with the same
tools but are secondary.

## Product Purpose

Track money moving through a group: who received what, whom it belongs to,
how much has arrived, and — netted across all payments — who pays whom to be
even. Success: after recording a payment the partners trust the balance
without a spreadsheet and settle with as few transfers as possible.

## Positioning

End-to-end encrypted and bring-your-own-server: the server only stores an
ordered log of ciphertext; members alone can read the ledger. Every payment
has two independent sides (who received / whom it belongs to), and money only
counts once its arrival is confirmed, instalment by instalment.

## Operating Context

- One group active at a time; members switch between a few groups.
- Payments are recorded right after an invoice is paid or a bill is split,
  often on the phone, sometimes days later.
- Joining is by a per-member invite QR code the admin shows; no accounts.
- The server owner (admin token) creates groups; the group creator is admin.

## Capabilities and Constraints

- Payment kinds: Income, Expense, Settle up — presets over one payment type.
- Each side accepts per-member amounts, percentages and one "rest" member;
  stored as exact minor-unit amounts that sum to the payment.
- Arrivals are recorded per receiver, in parts; only arrived money counts.
- One currency per group, fixed at creation.
- Offline-first: changes show immediately and sync later.
- Native iOS 26+ first (SwiftUI); Android and Windows later.

## Brand Commitments

- Name: Group Balance.
- Languages: English and German (informal "du").
- Vocabulary: Income / Eingang, Expense / Ausgabe, Settle up / Begleichen,
  arrived / angekommen, expected / erwartet, settled / quitt.

## Evidence on Hand

No real customer data, testimonials or logos. The colleague's Quitt app
(../quitt) is a functional reference for the payment editor, not a visual
authority.

## Product Principles

1. Money truth first: every number shown is derivable from the ledger and
   says whether it has arrived.
2. Recording a payment is fast and forgiving; the form does the arithmetic.
3. Nothing about the group's content is visible to anyone outside it.
4. Native first: a fluent iPhone user should never meet an off-spec control.

## Accessibility & Inclusion

Dynamic Type, Dark Mode and VoiceOver labels for amounts and actions; no
meaning carried by color alone (signs and words accompany red/green).
