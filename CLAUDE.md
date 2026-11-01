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
- No colors or fonts in views; tokens come from the `Design` package.
- UI copy in German and English (String Catalogs), German with informal "du".
- `ADMIN_TOKEN`, group secrets and private keys never appear in logs.
